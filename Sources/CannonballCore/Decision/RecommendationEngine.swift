import Foundation

/// A single prioritized instruction to the cabin. Arbitration in docs §3.8.
public struct Recommendation: Sendable, Identifiable, Equatable {
    public enum Kind: Int, Sendable, Comparable {
        // Descending priority
        case severeWatchdog = 0
        case bufferErosion
        case siteSwitch
        case stallSwitch
        case chargeLonger      // stay N min → skip a stop / net time win
        case departNow         // leave the plug — taper economics
        case departSoon        // target SOC imminent, wrap up
        case preconditionNow
        case paceDown          // arrive lower for peak-power charging
        case paceUp            // energy to burn — speed is free
        case chargeLimit       // car's limit will stop the session early
        case planB             // passing the last fallback charger on a risky leg
        case info

        public static func < (l: Kind, r: Kind) -> Bool { l.rawValue < r.rawValue }
    }

    public var id: String
    public var kind: Kind
    public var message: String          // spoken + displayed
    public var deltaSeconds: Double?    // time saved if followed
    public var isCritical: Bool         // Critical Alert channel
    public var issuedAt: Date
}

/// Top-level orchestrator: consumes fused vehicle state, owns the watchdog and
/// planners, emits at most one active recommendation at a time.
public actor RecommendationEngine {
    private var curve: ChargeCurveModel
    private var watchdog: ChargeWatchdog
    private let socTargets: SOCTargetCalculator
    private let scorer: SuperchargerScorer

    private var activePlan: TripPlan?
    private var teslaNavPlan: TripPlan?
    private var currentSession: ChargeSession?
    private var lastRecommendation: [Recommendation.Kind: Date] = [:]
    /// Per-kind cooldowns so the cabin isn't a nag machine at 3 a.m. in Kansas.
    private let cooldowns: [Recommendation.Kind: TimeInterval] = [
        .severeWatchdog: 120, .bufferErosion: 300, .siteSwitch: 600,
        .stallSwitch: 180, .chargeLonger: 300, .departNow: 120, .departSoon: 240,
        .preconditionNow: 600, .paceDown: 300, .paceUp: 420, .chargeLimit: 600,
        .planB: 300, .info: 900,
    ]

    private var continuation: AsyncStream<Recommendation>.Continuation?
    public private(set) var recommendations: AsyncStream<Recommendation>!

    public init(pack: PackProfile, energy: EnergyModel) {
        let curve = ChargeCurveModel(profile: pack)
        self.curve = curve
        self.watchdog = ChargeWatchdog(curve: curve)
        self.socTargets = SOCTargetCalculator(pack: pack, energy: energy)
        self.scorer = SuperchargerScorer(curve: curve, socTargets: socTargets)
        recommendations = AsyncStream { self.continuation = $0 }
    }

    public func attach(states: AsyncStream<VehicleState>,
                       corridor: @escaping @Sendable () async -> [SuperchargerScorer.Candidate],
                       teslaNavSiteID: @escaping @Sendable () async -> String?) {
        Task {
            for await state in states {
                await self.tick(state, corridor: corridor, teslaNavSiteID: teslaNavSiteID)
            }
        }
    }

    // MARK: per-tick

    private func tick(_ vehicle: VehicleState,
                      corridor: () async -> [SuperchargerScorer.Candidate],
                      teslaNavSiteID: () async -> String?) async {
        if vehicle.isDCFastCharging.value {
            await chargingTick(vehicle, corridor: corridor)
        } else {
            currentSession = nil
            await drivingTick(vehicle, corridor: corridor, teslaNavSiteID: teslaNavSiteID)
        }
    }

    private func chargingTick(_ vehicle: VehicleState,
                              corridor: () async -> [SuperchargerScorer.Candidate]) async {
        guard let site = await currentSite(corridor: corridor) else { return }
        if currentSession == nil {
            watchdog.beginSession()
            let target = activeTargetSOC() ?? 60
            currentSession = ChargeSession(siteID: site.id, startedAt: .init(),
                                           socStart: vehicle.socPercent.value,
                                           targetSOC: target)
        }
        let verdict = watchdog.tick(vehicle: vehicle, site: site,
                                    pairedNeighborOccupied: nil)
        currentSession?.samples.append(ChargeSample(
            t: .init(), socPercent: vehicle.socPercent.value,
            expectedKW: verdict.expectedKW, actualKW: vehicle.chargePowerKW.value,
            cellTempMaxC: vehicle.cellTempMaxC.value,
            bmsLimitKW: vehicle.bmsMaxChargeKW.value, limitReason: verdict.reason))

        if let event = verdict.newEvent {
            currentSession?.events.append(event)
            let kind: Recommendation.Kind = switch (event.state, event.reason) {
            case (.severe, .badStall), (.severe, .sharedPower): .severeWatchdog
            case (.degraded, .sharedPower), (.degraded, .badStall): .stallSwitch
            default: .info
            }
            emit(kind: kind, message: event.recommendation ?? "Charge state: \(event.state.rawValue)",
                 critical: kind == .severeWatchdog)
        }

        // Depart-now: the single biggest recurring win — recomputed live.
        if let target = activeTargetSOC() {
            let soc = vehicle.socPercent.value
            if soc >= target {
                emit(kind: .departNow,
                     message: "Target \(Int(target))% reached. Unplug and go.",
                     critical: false)
            } else if target - soc <= 4 {
                // Countdown so unplugging is instant, not a scramble.
                let kWhToGo = (target - soc) / 100 * curve.profile.usableKWh
                let minutes = kWhToGo / max(20, vehicle.chargePowerKW.value) * 60
                if minutes <= 3 {
                    emit(kind: .departSoon,
                         message: "About \(max(1, Int(minutes.rounded()))) min to \(Int(target))%. Wrap up and be ready to unplug.",
                         critical: false)
                }
            }
        }
    }

    private func drivingTick(_ vehicle: VehicleState,
                             corridor: () async -> [SuperchargerScorer.Candidate],
                             teslaNavSiteID: () async -> String?) async {
        // Buffer erosion check against the active leg.
        if let leg = activePlan?.legs.first,
           let advisory = socTargets.bufferAdvisory(currentSOC: vehicle.socPercent.value,
                                                    remainingLeg: leg) {
            emit(kind: .bufferErosion, message: advisory, critical: advisory.contains("below floor"))
        }
        // Challenge Tesla Nav whenever it has an intent.
        if let navSite = await teslaNavSiteID() {
            let candidates = await corridor()
            if let result = scorer.challenge(
                teslaNavSiteID: navSite, candidates: candidates,
                currentSOC: vehicle.socPercent.value,
                cellTempNowC: (vehicle.cellTempMinC.value, vehicle.cellTempMaxC.value),
                ambientC: vehicle.ambientTempC.value),
               result.recommendSwitch, let text = result.announcement {
                emit(kind: .siteSwitch, message: text, critical: false,
                     deltaSeconds: result.deltaSeconds)
            }
        }
    }

    // MARK: helpers

    private func activeTargetSOC() -> Double? { activePlan?.stops.first?.departureSOC }

    private func currentSite(corridor: () async -> [SuperchargerScorer.Candidate]) async -> Supercharger? {
        // Nearest candidate site; charging implies we're at one.
        await corridor().first?.site
    }

    public func updatePlans(optimized: TripPlan, teslaNav: TripPlan?) {
        activePlan = optimized
        teslaNavPlan = teslaNav
    }

    /// Forget everything learned about the current car (charge-curve
    /// residuals, watchdog state) — call when swapping vehicles.
    public func resetLearning() {
        let fresh = ChargeCurveModel(profile: curve.profile)
        curve = fresh
        watchdog = ChargeWatchdog(curve: fresh)
        currentSession = nil
    }

    /// Entry point for advisors computed outside the engine (charge coach,
    /// pace advice, precondition timing) — same arbitration and cooldowns.
    public func submit(kind: Recommendation.Kind, message: String,
                       deltaSeconds: Double? = nil, critical: Bool = false) {
        emit(kind: kind, message: message, critical: critical, deltaSeconds: deltaSeconds)
    }

    private func emit(kind: Recommendation.Kind, message: String,
                      critical: Bool, deltaSeconds: Double? = nil) {
        let now = Date()
        if let last = lastRecommendation[kind],
           now.timeIntervalSince(last) < (cooldowns[kind] ?? 300) { return }
        lastRecommendation[kind] = now
        continuation?.yield(Recommendation(
            id: "\(kind)-\(Int(now.timeIntervalSince1970))",
            kind: kind, message: message, deltaSeconds: deltaSeconds,
            isCritical: critical, issuedAt: now))
    }
}
