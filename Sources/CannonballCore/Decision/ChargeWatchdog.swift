import Foundation

/// Per-second actual-vs-expected charge power monitor. State machine and
/// diagnosis rules in docs §3.5.
public struct ChargeWatchdog: Sendable {
    public var curve: ChargeCurveModel
    public var degradedThreshold = 0.90
    public var severeThreshold = 0.70
    public var degradedDwell: TimeInterval = 45
    public var severeDwell: TimeInterval = 60
    public var rampUpGrace: TimeInterval = 60

    private var sessionStart: Date?
    private var belowDegradedSince: Date?
    private var belowSevereSince: Date?
    private var state: WatchdogState = .rampUp

    public init(curve: ChargeCurveModel) { self.curve = curve }

    public struct Verdict: Sendable {
        public var state: WatchdogState
        public var reason: ChargeLimitReason
        public var ratio: Double
        public var expectedKW: Double
        /// Non-nil when the state machine transitions — drive alerts off this.
        public var newEvent: WatchdogEvent?
        /// Healthy samples may feed curve residual learning.
        public var isLearnable: Bool
    }

    public mutating func beginSession(at date: Date = .init()) {
        sessionStart = date
        belowDegradedSince = nil; belowSevereSince = nil
        state = .rampUp
    }

    public mutating func tick(vehicle: VehicleState, site: Supercharger,
                              pairedNeighborOccupied: Bool?, now: Date = .init()) -> Verdict {
        let expected = curve.expectedKW(
            soc: vehicle.socPercent.value,
            cellTempMinC: vehicle.cellTempMinC.value,
            cellTempMaxC: vehicle.cellTempMaxC.value,
            siteVersion: site.version,
            bmsLimitKW: vehicle.bmsMaxChargeKW.value)
        let actual = vehicle.chargePowerKW.value
        let ratio = expected > 1 ? actual / expected : 1

        // Cloud-sourced power is coarse/delayed: widen tolerance (docs §2.3).
        let toleranceScale = vehicle.chargePowerKW.source == .can ? 1.0 : 0.85
        let degraded = degradedThreshold * toleranceScale
        let severe = severeThreshold * toleranceScale

        if let start = sessionStart, now.timeIntervalSince(start) < rampUpGrace {
            return Verdict(state: .rampUp, reason: .rampUp, ratio: ratio,
                           expectedKW: expected, newEvent: nil, isLearnable: false)
        }

        // Dwell tracking
        belowDegradedSince = ratio < degraded ? (belowDegradedSince ?? now) : nil
        belowSevereSince = ratio < severe ? (belowSevereSince ?? now) : nil

        let newState: WatchdogState
        if let s = belowSevereSince, now.timeIntervalSince(s) >= severeDwell {
            newState = .severe
        } else if let d = belowDegradedSince, now.timeIntervalSince(d) >= degradedDwell {
            newState = .degraded
        } else {
            newState = .healthy
        }

        let reason = diagnose(vehicle: vehicle, site: site,
                              pairedNeighborOccupied: pairedNeighborOccupied,
                              ratio: ratio, expected: expected)
        var event: WatchdogEvent?
        if newState != state {
            event = WatchdogEvent(t: now, state: newState, reason: reason, ratio: ratio,
                                  recommendation: recommendation(for: newState, reason: reason, site: site))
            state = newState
        }
        let learnable = newState == .healthy && reason == .none
        if learnable {
            curve.observe(soc: vehicle.socPercent.value, expected: expected, actual: actual)
        }
        return Verdict(state: newState, reason: reason, ratio: ratio,
                       expectedKW: expected, newEvent: event, isLearnable: learnable)
    }

    /// Order matters: explainable limits before blaming the stall.
    private func diagnose(vehicle: VehicleState, site: Supercharger,
                          pairedNeighborOccupied: Bool?, ratio: Double,
                          expected: Double) -> ChargeLimitReason {
        guard ratio < degradedThreshold else { return .none }
        let bmsBinding = vehicle.bmsMaxChargeKW.value < curve.vehicleExpectedKW(
            soc: vehicle.socPercent.value, cellTempMinC: 25, cellTempMaxC: 25) * 0.95
        if bmsBinding {
            if vehicle.cellTempMaxC.value > 50 { return .thermalHot }
            if vehicle.cellTempMinC.value < 15 { return .thermalCold }
        }
        if site.version.hasPairedStalls, pairedNeighborOccupied == true { return .sharedPower }
        return .badStall
    }

    private func recommendation(for state: WatchdogState, reason: ChargeLimitReason,
                                site: Supercharger) -> String? {
        switch (state, reason) {
        case (.degraded, .thermalHot), (.severe, .thermalHot):
            return "Pack thermally limited — stay plugged in; power recovers as SOC rises. ETA adjusted."
        case (.degraded, .thermalCold), (.severe, .thermalCold):
            return "Pack cold — power will ramp as it warms. Precondition timing missed; noted for next stop."
        case (.degraded, .sharedPower), (.severe, .sharedPower):
            return "Sharing a V2 cabinet. Move to an unpaired stall — saves several minutes."
        case (.degraded, .badStall):
            return "Stall underperforming. If it doesn't recover in 60 s, hop stalls (~90 s cost)."
        case (.severe, .badStall):
            return "Stall badly underperforming — re-scoring nearby sites now."
        default:
            return nil
        }
    }
}
