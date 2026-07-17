import Foundation

/// Times battery preconditioning so the pack arrives at the next DC stop in
/// the 40–50 °C acceptance window (docs §3.7). Trigger path: Fleet nav-share
/// (reliable) → Commander command if exposed → voice prompt fallback.
public struct PreconditionPlanner: Sendable {
    /// °C/min added by active preconditioning at highway speed (learned live;
    /// this is the prior).
    public var preconditionRateCPerMin = 0.65
    /// Passive drift toward (ambient + 15) °C while cruising, per hour.
    public var passiveApproachPerHour = 0.30
    public var targetWindowC: ClosedRange<Double> = 40...50

    public init() {}

    public struct Advice: Sendable, Equatable {
        public enum Action: Equatable { case startInMinutes(Int), startNow, skip(reason: String), tooLate }
        public var action: Action
        public var predictedArrivalTempNoPrecondition: Double
        public var predictedArrivalTempWithPrecondition: Double
    }

    public func advise(cellTempMaxC: Double, ambientC: Double,
                       minutesToArrival: Double) -> Advice {
        let hours = minutesToArrival / 60
        let equilibrium = ambientC + 15
        let passive = cellTempMaxC + (equilibrium - cellTempMaxC)
            * min(1, passiveApproachPerHour * hours)

        // Hot guard: pack will arrive warm enough (or too warm) on its own.
        if passive >= targetWindowC.lowerBound {
            let reason = passive > targetWindowC.upperBound
                ? "pack will arrive hot (\(Int(passive)) °C) — precondition would cost range and worsen taper"
                : "pack self-heats into the window (\(Int(passive)) °C at arrival)"
            return Advice(action: .skip(reason: reason),
                          predictedArrivalTempNoPrecondition: passive,
                          predictedArrivalTempWithPrecondition: passive)
        }

        // Minutes of active heating needed to hit the bottom of the window.
        let deficit = targetWindowC.lowerBound - passive
        let heatMinutes = deficit / preconditionRateCPerMin
        let slack = minutesToArrival - heatMinutes
        let withPrecondition = min(targetWindowC.lowerBound + 2,
                                   passive + preconditionRateCPerMin * min(minutesToArrival, heatMinutes + 2))
        if slack < -3 {
            // Can't reach the window; start anyway — every °C pays at the plug.
            return Advice(action: minutesToArrival > 2 ? .startNow : .tooLate,
                          predictedArrivalTempNoPrecondition: passive,
                          predictedArrivalTempWithPrecondition: withPrecondition)
        }
        if slack <= 2 {
            return Advice(action: .startNow,
                          predictedArrivalTempNoPrecondition: passive,
                          predictedArrivalTempWithPrecondition: withPrecondition)
        }
        return Advice(action: .startInMinutes(Int(slack.rounded())),
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
