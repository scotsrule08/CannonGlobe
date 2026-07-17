import Foundation

/// Computes the minimum departure SOC for the next leg — never "80%".
/// Algorithm in docs §3.3.
public struct SOCTargetCalculator: Sendable {
    public var pack: PackProfile
    public var energy: EnergyModel
    /// z-score on leg energy sigma; 1.3 ≈ 90th percentile confidence.
    public var bufferZ: Double = 1.3

    public init(pack: PackProfile, energy: EnergyModel) {
        self.pack = pack; self.energy = energy
    }

    public struct Target: Sendable {
        public var departureSOC: Double         // charge-to figure shown huge in UI
        public var predictedArrivalSOC: Double
        public var reserveSOC: Double           // buffer above the hard floor
        public var bindingConstraint: String    // human-readable "why"
    }

    /// Greedy per-leg target. The corridor DP may raise (never lower) this
    /// when a marginal minute now is cheaper than at the next stop.
    public func target(nextLeg: RouteLeg, dpFloorSOC: Double? = nil) -> Target {
        let (kWh, sigma) = energy.predict(leg: nextLeg)
        let legSOC = kWh / pack.usableKWh * 100
        let sigmaSOC = sigma / pack.usableKWh * 100

        // reserve = hard floor + z·σ of the leg-energy forecast
        let reserveSOC = (pack.bufferFloorSOC + bufferZ * sigmaSOC).rounded(toPlaces: 1)

        var departure = (legSOC + reserveSOC).rounded(toPlaces: 1)
        var why = "leg \(Int(nextLeg.distanceMi)) mi + \(reserveSOC)% reserve (σ=\(sigmaSOC.rounded(toPlaces: 1))%)"

        if let dpFloor = dpFloorSOC, dpFloor > departure {
            departure = dpFloor
            why = "raised by trip optimizer: charging is cheaper here than at the next stop"
        }
        departure = min(100, max(15, departure))
        return Target(departureSOC: departure,
                      predictedArrivalSOC: departure - legSOC,
                      reserveSOC: reserveSOC,
                      bindingConstraint: why)
    }

    /// Live re-check while driving: is forecast arrival SOC eroding below the
    /// floor? Returns advisory when action is needed well before crisis.
    public func bufferAdvisory(currentSOC: Double, remainingLeg: RouteLeg) -> String? {
        let (kWh, sigma) = energy.predict(leg: remainingLeg)
        let arrival = currentSOC - kWh / pack.usableKWh * 100
        let floorWithSigma = pack.bufferFloorSOC + bufferZ * (sigma / pack.usableKWh * 100)
        guard arrival < floorWithSigma else { return nil }
        if arrival < pack.bufferFloorSOC {
            return "Arrival \(arrival.rounded(toPlaces: 1))% is below floor — reduce set speed 5 mph or divert to nearer site now."
        }
        return "Buffer eroding: forecast arrival \(arrival.rounded(toPlaces: 1))% vs \(floorWithSigma.rounded(toPlaces: 1))% comfort line. Watching."
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
