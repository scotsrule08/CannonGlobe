import Foundation

/// Mid-session charge-length optimizer. While plugged in, re-solves the rest
/// of the trip at each candidate departure SOC ("leave now", "+5 min",
/// "+10 min"…) and compares door-to-door totals. This is what turns the DP
/// planner into live advice: "charge 10 more minutes to stretch past Limon,
/// saving 8 minutes overall" or "leave now — the curve is tapering."
public enum ChargeCoach {
    public struct Advice: Sendable, Equatable {
        public enum Call: Sendable, Equatable {
            /// Staying longer strictly loses time.
            case leaveNow(taper: Bool, currentKW: Double)
            /// Staying wins: `skipsStopID` set when the extra charge removes
            /// a whole stop from the plan.
            case chargeLonger(extraMinutes: Int, savesMinutes: Int, skipsStopID: String?)
        }
        public var call: Call
    }

    static let extraMinutesGrid: [Double] = [0, 5, 10, 15, 20, 30]
    /// Ignore differences smaller than this — bucket noise, not signal.
    static let significanceSeconds = 90.0

    public static func evaluate(planner: TripPlanner,
                                problem: TripPlanner.Problem,
                                curve: ChargeCurveModel,
                                siteVersion: SuperchargerVersion,
                                cellTemp: (min: Double, max: Double)) -> Advice? {
        let socNow = problem.currentSOC

        struct Option { var extra: Double; var total: Double; var solution: TripPlanner.Solution }
        var options: [Option] = []
        for extra in extraMinutesGrid {
            let soc = extra == 0 ? socNow
                : socAfterCharging(minutes: extra, from: socNow, curve: curve,
                                   cellTemp: cellTemp, siteVersion: siteVersion)
            guard soc < 99.5 || extra == 0 else { continue }
            var p = problem
            p.currentSOC = soc
            guard let solution = planner.solve(p) else { continue }
            options.append(Option(extra: extra, total: extra * 60 + solution.plan.totalRemainingSeconds,
                                  solution: solution))
        }
        guard let baseline = options.first(where: { $0.extra == 0 }),
              let best = options.min(by: { $0.total < $1.total })
        else { return nil }

        if best.extra == 0 {
            // Only call "leave now" when staying visibly loses — stay quiet
            // on a flat optimum instead of flip-flopping.
            guard let bestStay = options.filter({ $0.extra > 0 }).min(by: { $0.total < $1.total }),
                  bestStay.total - baseline.total > significanceSeconds
            else { return nil }
            let kWNow = curve.expectedKW(soc: socNow, cellTempMinC: cellTemp.min,
                                         cellTempMaxC: cellTemp.max, siteVersion: siteVersion)
            let kWPeak = curve.expectedKW(soc: 15, cellTempMinC: cellTemp.min,
                                          cellTempMaxC: cellTemp.max, siteVersion: siteVersion)
            return Advice(call: .leaveNow(taper: kWNow < kWPeak * 0.55, currentKW: kWNow))
        }

        let saves = baseline.total - best.total
        guard saves > significanceSeconds else { return nil }
        // Does the longer charge drop the baseline's next stop from the plan?
        let skipped = baseline.solution.plan.stops.first.flatMap { next in
            best.solution.plan.stops.contains { $0.siteID == next.siteID } ? nil : next.siteID
        }
        return Advice(call: .chargeLonger(extraMinutes: Int(best.extra),
                                          savesMinutes: Int((saves / 60).rounded()),
                                          skipsStopID: skipped))
    }

    /// SOC after `minutes` more on the plug, same integration + self-heating
    /// model as `ChargeCurveModel.secondsToCharge`, minus the handshake.
    static func socAfterCharging(minutes: Double, from soc: Double,
                                 curve: ChargeCurveModel,
                                 cellTemp: (min: Double, max: Double),
                                 siteVersion: SuperchargerVersion) -> Double {
        var s = soc
        var remaining = minutes * 60
        var (tMin, tMax) = cellTemp
        let step = 0.5
        while remaining > 0 && s < 100 {
            let p = max(1.0, curve.expectedKW(soc: s, cellTempMinC: tMin, cellTempMaxC: tMax,
                                              siteVersion: siteVersion))
            let dt = curve.profile.usableKWh * (step / 100) / p * 3600
            if dt > remaining {
                s += step * remaining / dt
                break
            }
            remaining -= dt
            let warmRate = 0.004 * p / 100
            tMin = min(45, tMin + warmRate * dt)
            tMax = min(48, tMax + warmRate * dt * 0.8)
            s += step
        }
        return min(100, s)
    }
}
