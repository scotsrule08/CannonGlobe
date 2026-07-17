import Foundation

/// Scores candidate Superchargers on *total time* and challenges Tesla Nav's
/// choice. Algorithm in docs §3.4.
public struct SuperchargerScorer: Sendable {
    public var curve: ChargeCurveModel
    public var socTargets: SOCTargetCalculator
    /// Minimum advantage before recommending a switch (hysteresis).
    public var switchThresholdSeconds: Double = 90
    /// Cost of relocating within a site (unplug, move, handshake).
    public var stallHopSeconds: Double = 90

    public init(curve: ChargeCurveModel, socTargets: SOCTargetCalculator) {
        self.curve = curve; self.socTargets = socTargets
    }

    public struct Candidate: Sendable {
        public var site: Supercharger
        public var legToSite: RouteLeg           // from current position
        public var legAfterSite: RouteLeg        // site → next planned stop
        public var westbound: Bool
        /// DP value function at this site: expected seconds site → destination.
        /// This term makes the score jointly optimal instead of greedy.
        public var downstreamSeconds: Double
        public init(site: Supercharger, legToSite: RouteLeg, legAfterSite: RouteLeg,
                    westbound: Bool, downstreamSeconds: Double) {
            self.site = site; self.legToSite = legToSite; self.legAfterSite = legAfterSite
            self.westbound = westbound; self.downstreamSeconds = downstreamSeconds
        }
    }

    public struct Score: Sendable {
        public var siteID: String
        public var totalSeconds: Double
        public var detourSeconds: Double
        public var queueSeconds: Double
        public var chargeSeconds: Double
        public var arrivalSOC: Double
        public var departureSOC: Double
        public var arrivalCellTempC: (min: Double, max: Double)
    }

    public func score(_ c: Candidate, currentSOC: Double,
                      cellTempNowC: (min: Double, max: Double),
                      ambientC: Double) -> Score {
        let pack = socTargets.pack
        let (legKWh, _) = socTargets.energy.predict(leg: c.legToSite)
        let arrivalSOC = currentSOC - legKWh / pack.usableKWh * 100

        // Thermal sim along the leg: cruise self-heats ~3 °C/h toward ambient+15.
        let hours = c.legToSite.trafficDriveSeconds / 3600
        let equilibrium = ambientC + 15
        func warm(_ t: Double) -> Double { t + (equilibrium - t) * min(1, 0.3 * hours) }
        let arrivalTemp = (min: warm(cellTempNowC.min), max: warm(cellTempNowC.max))

        let target = socTargets.target(nextLeg: c.legAfterSite)
        let chargeSeconds = curve.secondsToCharge(
            from: max(0, arrivalSOC), to: target.departureSOC,
            cellTempStartC: arrivalTemp, siteVersion: c.site.version)

        // Sharing penalty: V2 pairing or near-full V3 site power budget.
        let sharingFactor = expectedSharingFactor(c.site)
        let effectiveCharge = chargeSeconds / sharingFactor

        let detour = c.westbound ? c.site.detourSecondsWestbound : c.site.detourSecondsEastbound
        let queue = c.site.occupancy.waitProbability(totalStalls: c.site.stallCount) * 8 * 60
        let health = (1 - c.site.healthScore) * 4 * 60   // expected loss to broken stalls

        return Score(siteID: c.site.id,
                     totalSeconds: c.legToSite.trafficDriveSeconds + detour + queue
                                 + effectiveCharge + health + c.downstreamSeconds,
                     detourSeconds: detour, queueSeconds: queue,
                     chargeSeconds: effectiveCharge,
                     arrivalSOC: arrivalSOC, departureSOC: target.departureSOC,
                     arrivalCellTempC: arrivalTemp)
    }

    /// Expected power fraction after sharing (1.0 = full power).
    func expectedSharingFactor(_ site: Supercharger) -> Double {
        let busy: Double = switch site.occupancy {
        case .live(let available, let total, _): 1 - Double(available) / Double(max(1, total))
        case .predicted(let f): f
        case .unknown: 0.4
        }
        if site.version.hasPairedStalls {
            // P(paired neighbor occupied) ≈ busy fraction → ~50% power when hit.
            return 1 - busy * 0.5
        }
        // V3/V4 site power budget only matters when nearly full.
        return busy > 0.85 ? 0.85 : 1.0
    }

    public struct ChallengeResult: Sendable {
        public var recommendSwitch: Bool
        public var best: Score
        public var teslaNavChoice: Score
        public var deltaSeconds: Double
        public var announcement: String?
    }

    /// The Tesla Nav challenger: score the car's chosen site against all
    /// candidates; recommend only past the hysteresis threshold.
    public func challenge(teslaNavSiteID: String, candidates: [Candidate],
                          currentSOC: Double, cellTempNowC: (min: Double, max: Double),
                          ambientC: Double) -> ChallengeResult? {
        let scores = candidates.map {
            score($0, currentSOC: currentSOC, cellTempNowC: cellTempNowC, ambientC: ambientC)
        }
        guard let navScore = scores.first(where: { $0.siteID == teslaNavSiteID }),
              let best = scores.min(by: { $0.totalSeconds < $1.totalSeconds })
        else { return nil }

        let delta = navScore.totalSeconds - best.totalSeconds
        let switching = best.siteID != teslaNavSiteID && delta > switchThresholdSeconds
        let minutes = Int((delta / 60).rounded())
        return ChallengeResult(
            recommendSwitch: switching,
            best: best, teslaNavChoice: navScore, deltaSeconds: delta,
            announcement: switching
                ? "Better stop: \(best.siteID). Saves about \(minutes) minutes vs the car's plan. Arrive \(Int(best.arrivalSOC))%, charge to \(Int(best.departureSOC))%."
                : nil)
    }
}
