import Foundation

/// SOC-, temperature-, and site-limited charge power model with live residual
/// learning. Pure value math — safe to call from any actor.
public struct ChargeCurveModel: Sendable {
    public var profile: PackProfile
    /// Multiplicative residual per SOC decile (index 0 = 0–10% … 9 = 90–100%),
    /// learned from healthy sessions only. 1.0 = prior curve is right.
    public private(set) var residuals: [Double]
    private let residualAlpha = 0.15   // EWMA weight per observation

    public init(profile: PackProfile, residuals: [Double] = Array(repeating: 1.0, count: 10)) {
        self.profile = profile
        self.residuals = residuals
    }

    // MARK: Expected power

    /// Expected charge power for the *vehicle* at this SOC/temp, before site limits.
    public func vehicleExpectedKW(soc: Double, cellTempMinC: Double, cellTempMaxC: Double) -> Double {
        let base = Self.interpolate(profile.baseCurve.map { ($0.soc, $0.kW) }, at: soc)
        let cold = Self.interpolate(profile.coldFactor.map { ($0.tempC, $0.factor) }, at: cellTempMinC)
        let hot = Self.interpolate(profile.hotFactor.map { ($0.tempC, $0.factor) }, at: cellTempMaxC)
        let residual = residuals[max(0, min(9, Int(soc / 10)))]
        return base * min(cold, hot) * residual
    }

    /// Expected power including site + BMS ceilings — what the watchdog compares against.
    public func expectedKW(soc: Double, cellTempMinC: Double, cellTempMaxC: Double,
                           siteVersion: SuperchargerVersion,
                           bmsLimitKW: Double = .infinity) -> Double {
        min(vehicleExpectedKW(soc: soc, cellTempMinC: cellTempMinC, cellTempMaxC: cellTempMaxC),
            siteVersion.perCarCapKW,
            bmsLimitKW)
    }

    // MARK: Time integration

    /// Seconds to charge socFrom → socTo, integrating dt = C·dSOC / P(SOC) on a
    /// 0.5% grid. `cellTempC` is (min, max) at start; a simple warming model
    /// moves cells toward 45 °C as energy flows (DC charging self-heats).
    public func secondsToCharge(from socFrom: Double, to socTo: Double,
                                cellTempStartC: (min: Double, max: Double),
                                siteVersion: SuperchargerVersion) -> Double {
        guard socTo > socFrom else { return 0 }
        var seconds = 0.0
        var (tMin, tMax) = cellTempStartC
        var soc = socFrom
        let step = 0.5
        while soc < socTo {
            let p = max(1.0, expectedKW(soc: soc, cellTempMinC: tMin, cellTempMaxC: tMax,
                                        siteVersion: siteVersion))
            let dt = profile.usableKWh * (step / 100) / p * 3600
            seconds += dt
            // Warming: high-power charging pulls cells toward the 45 °C plateau.
            let warmRate = 0.004 * p / 100   // °C per second, ∝ power
            tMin = min(45, tMin + warmRate * dt)
            tMax = min(48, tMax + warmRate * dt * 0.8)
            soc += step
        }
        seconds += 45   // plug-in handshake + ramp overhead
        return seconds
    }

    // MARK: Learning

    /// Feed one healthy (unshared, non-BMS-limited) observation.
    public mutating func observe(soc: Double, expected: Double, actual: Double) {
        guard expected > 5 else { return }
        let i = max(0, min(9, Int(soc / 10)))
        let ratio = max(0.5, min(1.5, actual / expected))
        // EWMA toward the observed ratio: repeated identical observations
        // converge to the ratio instead of compounding without bound.
        residuals[i] += residualAlpha * (ratio - residuals[i])
    }

    // MARK: - Piecewise-linear interpolation over sorted (x, y) anchors.
    static func interpolate(_ table: [(Double, Double)], at x: Double) -> Double {
        guard let first = table.first, let last = table.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for (a, b) in zip(table, table.dropFirst()) where x >= a.0 && x <= b.0 {
            let f = (x - a.0) / (b.0 - a.0)
            return a.1 + f * (b.1 - a.1)
        }
        return last.1
    }
}
