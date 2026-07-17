import Foundation

/// Times battery preconditioning so the pack arrives at the next DC stop in
/// the 40–50 °C acceptance window (docs §3.7). Trigger path: Fleet nav-share
/// (reliable) → Commander command if exposed → voice prompt fallback.
public struct PreconditionPlanner: Sendable {
    /// °C/min added by active preconditioning at highway speed (learned live;
    /// this is the prior).
    public var preconditionRateCPerMin = 0.65
    /// °C/min removed by active pack cooling at highway speed. Compressor
    /// cooling is slower than resistive/motor-waste heating.
    public var precoolRateCPerMin = 0.45
    /// Passive drift toward (ambient + 15) °C while cruising, per hour.
    public var passiveApproachPerHour = 0.30
    public var targetWindowC: ClosedRange<Double> = 40...50

    public init() {}

    public struct Advice: Sendable, Equatable {
        public enum Action: Equatable { case startInMinutes(Int), startNow, skip(reason: String), tooLate }
        public enum Mode: Sendable, Equatable { case heat, cool }
        public var action: Action
        public var mode: Mode
        public var predictedArrivalTempNoPrecondition: Double
        public var predictedArrivalTempWithPrecondition: Double
    }

    /// Effective heating rate: the battery heater fights the outside air, so
    /// derate the warm-weather prior as ambient drops (≈1.0 above 15 °C,
    /// ~0.73 at 0 °C, floor 0.45 in arctic air).
    public func effectiveRateCPerMin(ambientC: Double) -> Double {
        preconditionRateCPerMin * max(0.45, min(1.0, 1.0 - (15 - ambientC) * 0.018))
    }

    /// Effective cooling rate: the A/C condenser fights hot outside air the
    /// mirror-image way (≈1.0 below 30 °C, ~0.85 at 40 °C, floor 0.5 in
    /// desert heat).
    public func effectiveCoolRateCPerMin(ambientC: Double) -> Double {
        precoolRateCPerMin * max(0.5, min(1.0, 1.0 - (ambientC - 30) * 0.015))
    }

    public func advise(cellTempMaxC: Double, ambientC: Double,
                       minutesToArrival: Double) -> Advice {
        let hours = minutesToArrival / 60
        let rate = effectiveRateCPerMin(ambientC: ambientC)
        let equilibrium = ambientC + 15
        let passive = cellTempMaxC + (equilibrium - cellTempMaxC)
            * min(1, passiveApproachPerHour * hours)

        // Overheat: arriving above the window hits the hot-side taper —
        // active precooling, derated by desert air, on the same slack math.
        if passive > targetWindowC.upperBound {
            let coolRate = effectiveCoolRateCPerMin(ambientC: ambientC)
            let coolTarget = targetWindowC.upperBound - 2
            let coolMinutes = (passive - coolTarget) / coolRate
            let slack = minutesToArrival - coolMinutes
            let withPrecool = max(coolTarget,
                                  passive - coolRate * min(minutesToArrival, coolMinutes + 2))
            let action: Advice.Action = if minutesToArrival <= 2 {
                .tooLate
            } else if slack <= 2 {
                .startNow
            } else {
                .startInMinutes(Int(slack.rounded()))
            }
            return Advice(action: action, mode: .cool,
                          predictedArrivalTempNoPrecondition: passive,
                          predictedArrivalTempWithPrecondition: withPrecool)
        }

        // In-window: pack self-heats into acceptance on its own.
        if passive >= targetWindowC.lowerBound {
            return Advice(action: .skip(reason:
                "pack self-heats into the window (\(Int(passive)) °C at arrival)"),
                          mode: .heat,
                          predictedArrivalTempNoPrecondition: passive,
                          predictedArrivalTempWithPrecondition: passive)
        }

        // Minutes of active heating needed to hit the bottom of the window,
        // at the ambient-derated rate.
        let deficit = targetWindowC.lowerBound - passive
        let heatMinutes = deficit / rate
        let slack = minutesToArrival - heatMinutes
        let withPrecondition = min(targetWindowC.lowerBound + 2,
                                   passive + rate * min(minutesToArrival, heatMinutes + 2))
        if slack < -3 {
            // Can't reach the window; start anyway — every °C pays at the plug.
            return Advice(action: minutesToArrival > 2 ? .startNow : .tooLate,
                          mode: .heat,
                          predictedArrivalTempNoPrecondition: passive,
                          predictedArrivalTempWithPrecondition: withPrecondition)
        }
        if slack <= 2 {
            return Advice(action: .startNow, mode: .heat,
                          predictedArrivalTempNoPrecondition: passive,
                          predictedArrivalTempWithPrecondition: withPrecondition)
        }
        return Advice(action: .startInMinutes(Int(slack.rounded())), mode: .heat,
                      predictedArrivalTempNoPrecondition: passive,
                      predictedArrivalTempWithPrecondition: withPrecondition)
    }

    /// Update the heating-rate prior from an observed precondition segment.
    public mutating func learn(observedDeltaC: Double, overMinutes: Double) {
        guard overMinutes > 3, observedDeltaC > 0 else { return }
        let observed = observedDeltaC / overMinutes
        preconditionRateCPerMin += 0.3 * (observed - preconditionRateCPerMin)
    }
}
