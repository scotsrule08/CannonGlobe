import Foundation

/// Corridor dynamic-programming trip optimizer (docs §3.2).
///
/// Backward DP over (site, SOC bucket) computes cost-to-go from every corridor
/// site to the destination. That gives us three things from one computation:
///  1. the optimized plan (greedy reconstruction from the current state),
///  2. the Tesla-Nav-pinned plan (same reconstruction with stop 1 forced),
///  3. `downstreamSeconds` for `SuperchargerScorer.Candidate` — the term that
///     makes site scoring jointly optimal instead of greedy.
public struct TripPlanner: Sendable {
    public var curve: ChargeCurveModel
    public var energy: EnergyModel
    public var pack: PackProfile

    /// SOC bucket width in % — 2% keeps the table small and the error < 1 min.
    let bucketPct = 2.0
    /// Fixed per-stop overhead beyond detour: park, plug, handshake, unplug.
    let stopOverheadSeconds = 120.0
    /// Max sites to fan out to from any stop (corridor is nearly linear).
    /// Dynamic corridors thin dense metro clusters to ~10 mi spacing and
    /// raise this so legs can still span 150+ mi.
    public var maxFanOut = 8
    /// A stop must add at least this many SOC buckets (3 × 2% = 6%). Paying
    /// stop overhead for a sliver of charge is never right, and without this
    /// floor the DP tie-breaks sliver top-ups onto high-SOC sites where the
    /// rate difference is only seconds. With it, the charge curve makes the
    /// late low-SOC site win decisively.
    public var minChargeBuckets = 3

    public init(curve: ChargeCurveModel, energy: EnergyModel, pack: PackProfile) {
        self.curve = curve; self.energy = energy; self.pack = pack
    }

    // MARK: Inputs

    /// Builds the drivable leg between two corridor route-miles from cached
    /// elevation + weather (`CorridorModel` in the app provides this).
    public typealias LegBuilder = @Sendable (_ fromMile: Double, _ toMile: Double) -> RouteLeg

    public struct Problem: Sendable {
        public var sites: [Supercharger]          // sorted by routeMile ascending
        public var destinationMile: Double
        public var currentMile: Double
        public var currentSOC: Double
        public var cellTempC: (min: Double, max: Double)
        public var westbound: Bool
        public var legBuilder: LegBuilder
        /// When set, the first stop is forced to this site (Tesla-Nav pinning).
        public var entryRestrictedTo: String? = nil
        public init(sites: [Supercharger], destinationMile: Double, currentMile: Double,
                    currentSOC: Double, cellTempC: (min: Double, max: Double),
                    westbound: Bool = true, legBuilder: @escaping LegBuilder) {
            self.sites = sites.sorted { $0.routeMile < $1.routeMile }
            self.destinationMile = destinationMile
            self.currentMile = currentMile; self.currentSOC = currentSOC
            self.cellTempC = cellTempC; self.westbound = westbound
            self.legBuilder = legBuilder
        }
    }

    public struct Solution: Sendable {
        public var plan: TripPlan
        /// Cost-to-go (seconds to destination) per siteID at its planned
        /// arrival SOC — feed `SuperchargerScorer.Candidate.downstreamSeconds`.
        public var downstreamSeconds: [String: Double]
        /// Full value table for ad-hoc queries: siteID → per-bucket seconds.
        public var valueTable: [String: [Double]]
    }

    // MARK: Solve

    public func solve(_ p: Problem) -> Solution? {
        let ahead = p.sites.filter { $0.routeMile > p.currentMile && $0.routeMile < p.destinationMile }
        let buckets = Int(100 / bucketPct) + 1
        // Ceil, not truncate: bucket(5.0) would be the 4% bucket, letting the
        // DP plan arrivals below the buffer floor.
        let floorBucket = Int((pack.bufferFloorSOC / bucketPct).rounded(.up))

        // Per-site precomputation: leg energy/time to the next few sites and to
        // the destination, and the cumulative charge-time table at this site.
        struct SiteCalc {
            var site: Supercharger
            var chargeCum: [Double]                  // cumulative seconds to reach bucket b from 0
            var next: [(index: Int, leg: RouteLeg, kWh: Double)]
            var toDest: (leg: RouteLeg, kWh: Double)?
        }
        var calcs: [SiteCalc] = []
        for (i, site) in ahead.enumerated() {
            var next: [(Int, RouteLeg, Double)] = []
            for j in (i + 1)..<min(ahead.count, i + 1 + maxFanOut) {
                let leg = p.legBuilder(site.routeMile, ahead[j].routeMile)
                next.append((j, leg, energy.predict(leg: leg).kWh))
            }
            let destLeg = p.legBuilder(site.routeMile, p.destinationMile)
            let destKWh = energy.predict(leg: destLeg).kWh
            calcs.append(SiteCalc(
                site: site,
                chargeCum: chargeCumulativeTable(site: site, cellTempC: p.cellTempC, buckets: buckets),
                next: next,
                toDest: (destLeg, destKWh)))
        }

        // value[i][b] = min seconds from arriving at site i with SOC bucket b
        // (before charging) to the destination. INF = infeasible.
        let inf = Double.greatestFiniteMagnitude
        var value = Array(repeating: Array(repeating: inf, count: buckets), count: ahead.count)
        var choice = Array(repeating: Array(repeating: (target: -1, nextIndex: -2), count: buckets),
                           count: ahead.count)

        for i in stride(from: ahead.count - 1, through: 0, by: -1) {
            let c = calcs[i]
            let overhead = stopDetourSeconds(c.site, westbound: p.westbound)
                + queueSeconds(c.site) + stopOverheadSeconds
            // Pinning means "the car CHARGES here" — without this, the DP
            // routes through the pinned site and charges somewhere better,
            // silently un-pinning the comparison.
            let mustChargeHere = p.entryRestrictedTo == c.site.id
            for b in floorBucket..<buckets {
                var best = inf
                var bestChoice = (target: -1, nextIndex: -2)
                for t in b..<buckets {
                    // Either pass through (t == b) or charge meaningfully.
                    if t == b {
                        if mustChargeHere { continue }
                    } else if t - b < minChargeBuckets { continue }
                    let chargeSec = c.chargeCum[t] - c.chargeCum[b]
                    let socOut = soc(t)
                    // Option A: run for the destination.
                    if let (destLeg, destKWh) = c.toDest {
                        let arrivalSOC = socOut - destKWh / pack.usableKWh * 100
                        if arrivalSOC >= pack.bufferFloorSOC {
                            let cost = (t > b ? overhead + chargeSec : 0) + destLeg.trafficDriveSeconds
                            if cost < best { best = cost; bestChoice = (t, -1) }
                        }
                    }
                    // Option B: hop to a later site.
                    for (j, leg, kWh) in c.next {
                        let arrivalSOC = socOut - kWh / pack.usableKWh * 100
                        // Feasibility on the continuous SOC; nearest bucket for
                        // the value lookup (truncating leaks up to 2% per hop).
                        guard arrivalSOC >= pack.bufferFloorSOC else { continue }
                        let ab = max(floorBucket, nearestBucket(arrivalSOC))
                        guard value[j][ab] < inf else { continue }
                        let cost = (t > b ? overhead + chargeSec : 0)
                            + leg.trafficDriveSeconds + value[j][ab]
                        if cost < best { best = cost; bestChoice = (t, j) }
                    }
                }
                value[i][b] = best
                choice[i][b] = bestChoice
            }
        }

        // Entry edges from the current position (mid-leg, no charging here).
        var entryBest = inf
        var entry: (index: Int, arrivalBucket: Int)? = nil
        for (i, c) in calcs.enumerated() {
            guard c.site.routeMile - p.currentMile < 400 else { break }
            if let pin = p.entryRestrictedTo, c.site.id != pin { continue }
            let leg = p.legBuilder(p.currentMile, c.site.routeMile)
            let kWh = energy.predict(leg: leg).kWh
            let arrivalSOC = p.currentSOC - kWh / pack.usableKWh * 100
            guard arrivalSOC >= pack.bufferFloorSOC else { continue }
            let ab = max(floorBucket, nearestBucket(arrivalSOC))
            guard value[i][ab] < inf else { continue }
            let cost = leg.trafficDriveSeconds + value[i][ab]
            if cost < entryBest { entryBest = cost; entry = (i, ab) }
        }
        // Direct-to-destination check (endgame) — suppressed when pinning.
        let directLeg = p.legBuilder(p.currentMile, p.destinationMile)
        let directKWh = energy.predict(leg: directLeg).kWh
        if p.entryRestrictedTo == nil,
           p.currentSOC - directKWh / pack.usableKWh * 100 >= pack.bufferFloorSOC,
           directLeg.trafficDriveSeconds <= entryBest {
            let plan = TripPlan(generatedAt: .init(), legs: [directLeg], stops: [],
                                totalRemainingSeconds: directLeg.trafficDriveSeconds)
            return Solution(plan: plan, downstreamSeconds: [:], valueTable: [:])
        }
        guard let start = entry else { return nil }   // infeasible: caller must widen corridor

        // Greedy reconstruction along the argmin chain. Pass-through sites
        // (t == b: drive by, charge nothing) are not stops, and their hops
        // are merged so legs[k] always spans stop k-1 → stop k. In
        // particular legs.first runs from the current position to the first
        // REAL stop — time-to-stop and arrival-SOC consumers depend on this.
        var stops: [PlannedStop] = []
        var legs: [RouteLeg] = []
        var segmentStartMile = p.currentMile
        var (i, b) = start
        while i >= 0 {
            let (t, nextIndex) = choice[i][b]
            guard t >= 0 else { break }
            let c = calcs[i]
            if t > b {
                legs.append(p.legBuilder(segmentStartMile, c.site.routeMile))
                segmentStartMile = c.site.routeMile
                stops.append(PlannedStop(
                    siteID: c.site.id,
                    arrivalSOC: soc(b), departureSOC: soc(t),
                    chargeSeconds: c.chargeCum[t] - c.chargeCum[b],
                    detourSeconds: stopDetourSeconds(c.site, westbound: p.westbound),
                    expectedQueueSeconds: queueSeconds(c.site)))
            }
            if nextIndex == -1 {
                legs.append(p.legBuilder(segmentStartMile, p.destinationMile))
                break
            }
            let (j, _, kWh) = c.next.first { $0.index == nextIndex }!
            let arrivalSOC = soc(t) - kWh / pack.usableKWh * 100
            (i, b) = (j, max(floorBucket, nearestBucket(arrivalSOC)))
        }

        var downstream: [String: Double] = [:]
        var table: [String: [Double]] = [:]
        for (i, c) in calcs.enumerated() {
            table[c.site.id] = value[i]
            if let planned = stops.first(where: { $0.siteID == c.site.id }) {
                downstream[c.site.id] = value[i][bucket(planned.arrivalSOC)]
            } else {
                // Best-case arrival for unplanned sites: cost-to-go at 10% SOC.
                downstream[c.site.id] = value[i][bucket(10)]
            }
        }
        let plan = TripPlan(generatedAt: .init(), legs: legs, stops: stops,
                            totalRemainingSeconds: entryBest)
        return Solution(plan: plan, downstreamSeconds: downstream, valueTable: table)
    }

    /// Same DP, but stop 1 pinned to the car's chosen site — the "Tesla Nav
    /// plan" whose total time the Compare screen diffs against the optimum.
    public func solvePinned(_ p: Problem, firstStopID: String) -> Solution? {
        var pinned = p
        pinned.entryRestrictedTo = firstStopID
        // Direct-to-destination shortcut must also be suppressed when pinning:
        // the comparison is "what does the car's plan cost", stop included.
        return solve(pinned)
    }

    // MARK: helpers

    func bucket(_ soc: Double) -> Int { max(0, min(Int(100 / bucketPct), Int(soc / bucketPct))) }
    func nearestBucket(_ soc: Double) -> Int {
        max(0, min(Int(100 / bucketPct), Int((soc / bucketPct).rounded())))
    }
    func soc(_ bucket: Int) -> Double { Double(bucket) * bucketPct }

    func stopDetourSeconds(_ s: Supercharger, westbound: Bool) -> Double {
        westbound ? s.detourSecondsWestbound : s.detourSecondsEastbound
    }

    func queueSeconds(_ s: Supercharger) -> Double {
        s.occupancy.waitProbability(totalStalls: s.stallCount) * 8 * 60
            + (1 - s.healthScore) * 4 * 60
    }

    /// Cumulative charge-time table: seconds to charge 0% → bucket b at this
    /// site, so any b→t charge time is one subtraction inside the DP loops.
    func chargeCumulativeTable(site: Supercharger, cellTempC: (min: Double, max: Double),
                               buckets: Int) -> [Double] {
        var cum = [0.0]
        var (tMin, tMax) = cellTempC
        for b in 1..<buckets {
            let socMid = (Double(b) - 0.5) * bucketPct
            let p = max(1.0, curve.expectedKW(soc: socMid, cellTempMinC: tMin,
                                              cellTempMaxC: tMax, siteVersion: site.version))
            let dt = pack.usableKWh * (bucketPct / 100) / p * 3600
            cum.append(cum[b - 1] + dt)
            let warmRate = 0.004 * p / 100
            tMin = min(45, tMin + warmRate * dt)
            tMax = min(48, tMax + warmRate * dt * 0.8)
        }
        return cum
    }
}
