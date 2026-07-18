import Foundation
import CoreLocation

/// Consumes all source streams and emits a coalesced `VehicleState` at 1 Hz,
/// plus immediately on significant deltas. Per-signal source priority and
/// freshness rules are in docs §2.3.
public actor DataFusionEngine {
    public struct Freshness {
        // seconds after which a source's value is ignored for that signal
        static let canFast: TimeInterval = 3       // power, current, voltage
        static let canSlow: TimeInterval = 5       // SOC, temps, limits
        static let cloudStream: TimeInterval = 30
        static let cloudREST: TimeInterval = 90
        static let gps: TimeInterval = 2
    }

    private var current: VehicleState
    private var continuation: AsyncStream<VehicleState>.Continuation?
    public private(set) var states: AsyncStream<VehicleState>!

    private var lastEmit: Date = .distantPast
    private var lastEmittedChargeKW: Double = 0

    public init(initial: VehicleState) {
        current = initial
        states = AsyncStream { self.continuation = $0 }
    }

    /// Wire the three inputs; each loop runs until its stream finishes.
    public func attach(panda: PandaClient, tessie: TessieClient,
                       gps: AsyncStream<CLLocation>) {
        Task { for await signal in await panda.signals { self.apply(can: signal) } }
        Task { for await cloud in await tessie.updates { self.apply(cloud: cloud) } }
        Task { for await fix in gps { self.apply(gps: fix) } }
        Task { // 1 Hz heartbeat emit + dead-reckoning maintenance
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.tick()
            }
        }
    }

    // MARK: apply — CAN wins whenever fresh

    private func apply(can signal: CANSignal) {
        let now = Date()
        switch signal {
        case let .packVoltAmp(volts, amps):
            current.packVoltage = .init(volts, source: .can, timestamp: now)
            current.packCurrentA = .init(amps, source: .can, timestamp: now)
            if current.isDCFastCharging.value {
                current.chargePowerKW = .init(max(0, -volts * amps / 1000), source: .can, timestamp: now)
            }
        case let .soc(ui, _, _):
            current.socPercent = .init(ui, source: .can, timestamp: now)
        case let .energyStatus(remaining, _):
            current.usableKWhRemaining = .init(remaining, source: .can, timestamp: now)
        case let .cellTemps(minC, maxC):
            current.cellTempMinC = .init(minC, source: .can, timestamp: now)
            current.cellTempMaxC = .init(maxC, source: .can, timestamp: now)
            current.cellTempAvgC = .init((minC + maxC) / 2, source: .can, timestamp: now)
        case let .bmsPowerLimits(charge, discharge):
            current.bmsMaxChargeKW = .init(charge, source: .can, timestamp: now)
            current.bmsMaxDischargeKW = .init(discharge, source: .can, timestamp: now)
        case let .fastChargeStatus(active, power):
            current.isDCFastCharging = .init(active, source: .can, timestamp: now)
            current.chargePowerKW = .init(power, source: .can, timestamp: now)
        case let .temps(ambient, cabin):
            current.ambientTempC = .init(ambient, source: .can, timestamp: now)
            current.cabinTempC = .init(cabin, source: .can, timestamp: now)
        case let .speedOdometer(speed, odo):
            if current.speedMps.source != .phoneGPS || current.speedMps.age(now: now) > Freshness.gps {
                current.speedMps = .init(speed, source: .can, timestamp: now)
            }
            current.odometerMi = .init(odo, source: .can, timestamp: now)
        case let .fsdState(engaged):
            current.fsdEngaged = .init(engaged, source: .can, timestamp: now)
        case let .preconditionState(status):
            current.precondition = .init(status, source: .can, timestamp: now)
        }
        emitIfSignificant()
    }

    // MARK: apply — cloud fills only signals whose better source is stale

    private func apply(cloud s: CloudVehicleState) {
        let now = Date()
        func fill<T>(_ keyPath: WritableKeyPath<VehicleState, Tagged<T>>,
                     _ value: T?, canStale: TimeInterval) {
            guard let value else { return }
            let existing = current[keyPath: keyPath]
            if existing.source == .can, existing.age(now: now) < canStale { return }
            current[keyPath: keyPath] = .init(value, source: .tessieStream, timestamp: now)
        }
        fill(\.socPercent, s.socPercent, canStale: Freshness.canSlow)
        fill(\.chargePowerKW, s.chargerPowerKW, canStale: Freshness.canFast)
        fill(\.ambientTempC, s.outsideTempC, canStale: Freshness.canSlow)
        fill(\.cellTempMinC, s.moduleTempMinC, canStale: Freshness.canSlow)
        fill(\.cellTempMaxC, s.moduleTempMaxC, canStale: Freshness.canSlow)
        fill(\.packVoltage, s.packVoltage, canStale: Freshness.canFast)
        fill(\.packCurrentA, s.packCurrentA, canStale: Freshness.canFast)
        fill(\.usableKWhRemaining, s.energyRemainingKWh, canStale: Freshness.canSlow)
        fill(\.cabinTempC, s.insideTempC, canStale: Freshness.canSlow)
        // "Charging" alone can be a garage L2 — require the DC flag when the
        // API provides it so fast-charge logic never fires at home.
        let charging = (s.chargingState == "Charging" || s.chargingState == "Supercharging")
            && (s.fastChargerPresent ?? true)
        fill(\.isDCFastCharging, charging, canStale: Freshness.canSlow)
        if current.coordinate.source != .phoneGPS || current.coordinate.age(now: now) > Freshness.gps {
            current.coordinate = .init(.init(latitude: s.latitude, longitude: s.longitude),
                                       source: .tessieStream, timestamp: now)
        }
        emitIfSignificant()
    }

    private func apply(gps fix: CLLocation) {
        current.coordinate = .init(fix.coordinate, source: .phoneGPS, timestamp: fix.timestamp)
        if fix.speed >= 0 {
            current.speedMps = .init(fix.speed, source: .phoneGPS, timestamp: fix.timestamp)
        }
        if fix.course >= 0 {
            current.headingDeg = .init(fix.course, source: .phoneGPS, timestamp: fix.timestamp)
        }
    }

    // MARK: emit

    private func tick() {
        deadReckonIfStale()
        emit()
    }

    /// SOC dead-reckoning when both CAN and cloud are stale: coulomb-count
    /// from last-known pack power. Tagged `.deadReckoned` so the UI can show it.
    private func deadReckonIfStale() {
        let now = Date()
        guard current.socPercent.age(now: now) > 60,
              current.socPercent.source != .deadReckoned || current.socPercent.age(now: now) > 1
        else { return }
        let hours = min(current.socPercent.age(now: now), 5) / 3600
        let deltaKWh = current.packPowerKW * hours
        let usable = max(current.usableKWhRemaining.value, 1)
        let newSOC = max(0, min(100, current.socPercent.value - deltaKWh / usable * current.socPercent.value))
        current.socPercent = .init(newSOC, source: .deadReckoned, timestamp: now)
    }

    private func emitIfSignificant() {
        let significant =
            abs(current.chargePowerKW.value - lastEmittedChargeKW) > 5 ||
            Date().timeIntervalSince(lastEmit) > 1
        if significant { emit() }
    }

    private func emit() {
        current.timestamp = .init()
        lastEmit = current.timestamp
        lastEmittedChargeKW = current.chargePowerKW.value
        continuation?.yield(current)
    }
}
