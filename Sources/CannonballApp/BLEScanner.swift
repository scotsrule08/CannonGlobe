import Foundation
import CoreBluetooth

/// Field-probe BLE scanner + inspector: lists nearby peripherals, then on
/// demand connects to one and enumerates its GATT, subscribing to notify
/// characteristics to reveal where (and whether) CAN data streams. Read-only
/// discovery — never writes to a device.
@MainActor
final class BLEScanner: NSObject, ObservableObject {
    struct Found: Identifiable, Sendable {
        var id: UUID
        var name: String
        var rssi: Int
        var services: [String]
    }
    struct CharInfo: Identifiable, Sendable {
        var id: String              // "service/char"
        var service: String
        var characteristic: String
        var properties: String
        var notifying: Bool
        var packets: Int
        var lastBytes: String
    }

    @Published var devices: [Found] = []
    @Published var stateText = "Idle"
    @Published var scanning = false

    // Inspection state
    @Published var inspectName = ""
    @Published var inspectState = ""
    @Published var chars: [CharInfo] = []

    private var central: CBCentralManager?
    private var seen: [UUID: Found] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var charIndex: [CBUUID: Int] = [:]
    private var stopWorkItem: DispatchWorkItem?
    private var pendingConnectID: UUID?

    func start(seconds: Double = 8) {
        seen = [:]; devices = []; scanning = true
        stateText = "Starting Bluetooth…"
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { beginScan() }
        let stop = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: stop)
    }

    func stop() {
        stopWorkItem?.cancel()
        central?.stopScan()
        scanning = false
        if !devices.isEmpty { stateText = "Found \(devices.count) devices" }
        else if stateText.hasPrefix("Scanning") { stateText = "No devices found" }
    }

    func inspect(_ device: Found) {
        guard let peripheral = peripherals[device.id], let central else { return }
        central.stopScan(); scanning = false
        chars = []; charIndex = [:]
        inspectName = device.name
        inspectState = "Connecting…"
        active = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func disconnect() {
        if let active { central?.cancelPeripheralConnection(active) }
        active = nil; inspectName = ""; inspectState = ""; chars = []
    }

    private func beginScan() {
        stateText = "Scanning…"
        central?.scanForPeripherals(withServices: nil,
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: beginScan()
            case .poweredOff: stateText = "Bluetooth is off"; scanning = false
            case .unauthorized: stateText = "Bluetooth not allowed for CannonGlobe"; scanning = false
            case .unsupported: stateText = "Bluetooth unsupported"; scanning = false
            default: stateText = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "(unnamed)"
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString } ?? []
        Task { @MainActor in
            peripherals[peripheral.identifier] = peripheral
            seen[peripheral.identifier] = Found(id: peripheral.identifier, name: name,
                                                rssi: RSSI.intValue, services: uuids)
            devices = seen.values.sorted { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            inspectState = "Connected — discovering services…"
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in inspectState = "Connect failed: \(error?.localizedDescription ?? "unknown")" }
    }
}

extension BLEScanner: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services, !services.isEmpty else {
                inspectState = "No services found"; return
            }
            inspectState = "Discovering characteristics in \(services.count) service(s)…"
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let svc = service.uuid.uuidString
        let items: [(CBUUID, String, Bool)] = (service.characteristics ?? []).map {
            var props: [String] = []
            if $0.properties.contains(.notify) { props.append("notify") }
            if $0.properties.contains(.indicate) { props.append("indicate") }
            if $0.properties.contains(.read) { props.append("read") }
            if $0.properties.contains(.write) { props.append("write") }
            if $0.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            let streams = $0.properties.contains(.notify) || $0.properties.contains(.indicate)
            return ($0.uuid, props.joined(separator: ","), streams)
        }
        let notifyChars = (service.characteristics ?? []).filter {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        Task { @MainActor in
            for (uuid, props, streams) in items {
                let info = CharInfo(id: "\(svc)/\(uuid.uuidString)", service: svc,
                                    characteristic: uuid.uuidString, properties: props,
                                    notifying: streams, packets: 0, lastBytes: "")
                charIndex[uuid] = chars.count
                chars.append(info)
            }
            inspectState = "Subscribed — watching for data…"
        }
        // Subscribe to every streaming characteristic to see where CAN flows.
        for char in notifyChars { peripheral.setNotifyValue(true, for: char) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let data = characteristic.value ?? Data()
        let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        Task { @MainActor in
            guard let idx = charIndex[uuid] else { return }
            chars[idx].packets += 1
            chars[idx].lastBytes = hex + (data.count > 16 ? "…(\(data.count)B)" : "")
        }
    }
}
