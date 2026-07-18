import Foundation
import CoreBluetooth

/// Field-probe BLE scanner: lists nearby peripherals with their advertised
/// service UUIDs so we can identify the S3XY Commander / CANdy and map its
/// GATT. Read-only discovery — no writes to any device.
@MainActor
final class BLEScanner: NSObject, ObservableObject {
    struct Found: Identifiable, Sendable {
        var id: UUID
        var name: String
        var rssi: Int
        var services: [String]
        var connectable: Bool
    }

    @Published var devices: [Found] = []
    @Published var stateText = "Idle"
    @Published var scanning = false

    private var central: CBCentralManager?
    private var seen: [UUID: Found] = [:]
    private var stopWorkItem: DispatchWorkItem?

    func start(seconds: Double = 8) {
        seen = [:]
        devices = []
        scanning = true
        stateText = "Starting Bluetooth…"
        central = CBCentralManager(delegate: self, queue: .main)
        let stop = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: stop)
    }

    func stop() {
        stopWorkItem?.cancel()
        central?.stopScan()
        scanning = false
        if devices.isEmpty && stateText.hasPrefix("Scanning") {
            stateText = "Scan complete — no devices found"
        } else if !devices.isEmpty {
            stateText = "Found \(devices.count) device\(devices.count == 1 ? "" : "s")"
        }
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                stateText = "Scanning…"
                central.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            case .poweredOff:
                stateText = "Bluetooth is off — enable it in Control Center"
                scanning = false
            case .unauthorized:
                stateText = "Bluetooth not allowed — enable it for CannonGlobe in Settings"
                scanning = false
            case .unsupported:
                stateText = "Bluetooth unsupported on this device"
                scanning = false
            default:
                stateText = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "(unnamed)"
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString } ?? []
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?
            .boolValue ?? false
        let found = Found(id: peripheral.identifier, name: name,
                          rssi: RSSI.intValue, services: uuids, connectable: connectable)
        Task { @MainActor in
            seen[peripheral.identifier] = found
            devices = seen.values.sorted { $0.rssi > $1.rssi }
        }
    }
}
