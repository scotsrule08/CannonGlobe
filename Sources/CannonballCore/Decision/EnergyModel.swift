import Foundation

/// Physics consumption model for the 2025 M3 RWD Highland, with free
/// parameters owned/updated by `EfficiencyLearner`. Formulas in docs §3.1.
public struct EnergyModel: Sendable {
    // Learner-adjusted effective parameters
    public var cdAEffective: Double = 0.219 * 2.22    // m² (Cd·A)
    public var crrEffective: Double = 0.009
    public var massKg: Double = 1780 + 180            // Premium RWD curb + driver/co-driver + gear
    public var drivetrainEfficiency: Double = 0.92
    public var regenEfficiency: Double = 0.65
    public var hvacBiasKW: Double = 0.0               // learner residual
    public var baseLoadKW: Double = 0.35

    public init() {}

    /// Air density from temperature and altitude (ideal gas, std lapse).
    public func airDensity(tempC: Double, altitudeM: Double) -> Double {
        let seaLevel = 101_325 * pow(1 - 2.25577e-5 * altitudeM, 5.25588)
        return seaLevel / (287.05 * (tempC + 273.15))
    }

    public func hvacKW(ambientC: Double, cabinSetC: Double = 21) -> Double {
        // Heat pump COP-shaped: mild ambient ≈ trivial load, extremes ramp.
        let delta = abs(ambientC - cabinSetC)
        let base = ambientC < cabinSetC
            ? 0.25 * delta * (ambientC < -5 ? 1.6 : 1.0)   // heating, COP drops in deep cold
            : 0.12 * delta                                  // cooling
        return min(4.5, base) + hvacBiasKW
    }

    /// Instantaneous tractive + hotel power in kW at speed v (m/s).
    public func powerKW(speedMps v: Double, gradePercent: Double,
                        headwindMps: Double, tempC: Double, altitudeM: Double) -> Double {
        let rho = airDensity(tempC: tempC, altitudeM: altitudeM)
        let vAir = max(0, v + headwindMps)
        let aero = 0.5 * rho * cdAEffective * vAir * vAir * v
        let crr = crrEffective * (tempC < 5 ? 1.12 : 1.0)   // cold tires/grease
        let rolling = massKg * 9.81 * crr * v
        let grade = massKg * 9.81 * (gradePercent / 100) * v
        let tractive: Double
        if aero + rolling + grade >= 0 {
            tractive = (aero + rolling + grade) / drivetrainEfficiency
        } else {
            tractive = (aero + rolling + grade) * regenEfficiency  // descent credit
        }
        return tractive / 1000 + hvacKW(ambientC: tempC) + baseLoadKW
    }

    /// Predicted energy for a leg, integrating over the elevation profile.
    /// Returns (kWh, sigmaKWh) — sigma from wind-forecast error + model residual.
    public func predict(leg: RouteLeg, modelResidualSigmaFraction: Double = 0.03)
        -> (kWh: Double, sigmaKWh: Double) {
        let profile = leg.elevation
        guard profile.elevationsM.count > 1, leg.avgSpeedMps > 1 else {
            return (0, 0)
        }
        let step = profile.stepMeters
        var kWh = 0.0
        for (e0, e1) in zip(profile.elevationsM, profile.elevationsM.dropFirst()) {
            let grade = Double(e1 - e0) / step * 100
            let p = powerKW(speedMps: leg.avgSpeedMps, gradePercent: grade,
                            headwindMps: leg.wind.headwindMps,
                            tempC: leg.ambientTempC, altitudeM: Double(e0))
            kWh += max(0.0, p) * (step / leg.avgSpeedMps) / 3600
        }
        // Wind sensitivity: dE/dw ≈ ρ·CdA·(v+w)·v · distance
        let rho = airDensity(tempC: leg.ambientTempC,
                             altitudeM: Double(profile.elevationsM.first ?? 0))
        let distanceM = leg.distanceMi * 1609.34
        let dEdW = rho * cdAEffective * (leg.avgSpeedMps + leg.wind.headwindMps)
            * distanceM / drivetrainEfficiency / 3.6e6
        let windSigma = abs(dEdW) * leg.wind.sigmaMps
        let modelSigma = kWh * modelResidualSigmaFraction
        return (kWh, (windSigma * windSigma + modelSigma * modelSigma).squareRoot())
    }
}
