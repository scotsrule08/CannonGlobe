import Foundation
import CoreLocation

/// Where a fused signal value came from, in descending trust order.
public enum SourceTag: String, Codable, Sendable {
    case can          // S3XY Commander / Panda CAN
    case phoneGPS
    case tessieStream
    case tessieREST
    case fleetAPI
    case deadReckoned // model-predicted / coulomb-counted
}

/// A signal value with provenance and age, so consumers can reason about trust.
public struct Tagged<Value: Sendable & Codable>: Sendable, Codable {
    public var value: Value
    public var source: SourceTag
    public var timestamp: Date

    public init(_ value: Value, source: SourceTag, timestamp: Date = .init()) {
        self.value = value
        self.source = source
        self.timestamp = timestamp
    }

    public func age(now: Date = .init()) -> TimeInterval { now.timeIntervalSince(timestamp) }
}

public enum PreconditionStatus: String, Codable, Sendable {
    case off, requested, heating, atTemperature, unavailable
}

/// Canonical fused vehicle snapshot, emitted at 1 Hz (and on significant deltas)
/// by `DataFusionEngine`.
public struct VehicleState: Sendable, Codable {
    public var timestamp: Date

    // Position & motion
    public var coordinate: Tagged<CLLocationCoordinate2D>
    public var speedMps: Tagged<Double>
    public var headingDeg: Tagged<Double>
    public var odometerMi: Tagged<Double>

    // Energy
    public var socPercent: Tagged<Double>          // indicated SOC 0–100
    public var usableKWhRemaining: Tagged<Double>
    public var packVoltage: Tagged<Double>
    public var packCurrentA: Tagged<Double>        // + discharge, − charge
    /// Convenience: signed pack power in kW (− while charging).
    public var packPowerKW: Double { packVoltage.value * packCurrentA.value / 1000 }

    // Thermal
    public var cellTempMinC: Tagged<Double>
    public var cellTempAvgC: Tagged<Double>
    public var cellTempMaxC: Tagged<Double>
    public var ambientTempC: Tagged<Double>
    public var cabinTempC: Tagged<Double>
    public var precondition: Tagged<PreconditionStatus>

    // BMS envelopes
    public var bmsMaxChargeKW: Tagged<Double>
    public var bmsMaxDischargeKW: Tagged<Double>

    // Charging
    public var isDCFastCharging: Tagged<Bool>
    public var chargePowerKW: Tagged<Double>       // ≥ 0 while charging
    public var chargerMaxCurrentA: Tagged<Double>

    // Autonomy
    public var fsdEngaged: Tagged<Bool>

    public init(timestamp: Date,
                coordinate: Tagged<CLLocationCoordinate2D>, speedMps: Tagged<Double>,
                headingDeg: Tagged<Double>, odometerMi: Tagged<Double>,
                socPercent: Tagged<Double>, usableKWhRemaining: Tagged<Double>,
                packVoltage: Tagged<Double>, packCurrentA: Tagged<Double>,
                cellTempMinC: Tagged<Double>, cellTempAvgC: Tagged<Double>,
                cellTempMaxC: Tagged<Double>, ambientTempC: Tagged<Double>,
                cabinTempC: Tagged<Double>, precondition: Tagged<PreconditionStatus>,
                bmsMaxChargeKW: Tagged<Double>, bmsMaxDischargeKW: Tagged<Double>,
                isDCFastCharging: Tagged<Bool>, chargePowerKW: Tagged<Double>,
                chargerMaxCurrentA: Tagged<Double>, fsdEngaged: Tagged<Bool>) {
        self.timestamp = timestamp
        self.coordinate = coordinate; self.speedMps = speedMps
        self.headingDeg = headingDeg; self.odometerMi = odometerMi
        self.socPercent = socPercent; self.usableKWhRemaining = usableKWhRemaining
        self.packVoltage = packVoltage; self.packCurrentA = packCurrentA
        self.cellTempMinC = cellTempMinC; self.cellTempAvgC = cellTempAvgC
        self.cellTempMaxC = cellTempMaxC; self.ambientTempC = ambientTempC
        self.cabinTempC = cabinTempC; self.precondition = precondition
        self.bmsMaxChargeKW = bmsMaxChargeKW; self.bmsMaxDischargeKW = bmsMaxDischargeKW
        self.isDCFastCharging = isDCFastCharging; self.chargePowerKW = chargePowerKW
        self.chargerMaxCurrentA = chargerMaxCurrentA; self.fsdEngaged = fsdEngaged
    }
}

extension CLLocationCoordinate2D: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(latitude: try c.decode(Double.self), longitude: try c.decode(Double.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(latitude); try c.encode(longitude)
    }
}
