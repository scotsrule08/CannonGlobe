import Foundation
import Network

/// One decoded CAN frame off the Panda wire format.
public struct CANFrame: Sendable {
    public var address: UInt32
    public var bus: UInt8
    public var data: Data          // up to 8 bytes (classic CAN)
    public var receivedAt: Date
}

/// Typed telemetry decoded from CAN, published to the fusion engine.
public enum CANSignal: Sendable {
    case packVoltAmp(volts: Double, amps: Double)
    case soc(uiPercent: Double, minPercent: Double, maxPercent: Double)
    case energyStatus(remainingKWh: Double, fullKWh: Double)
    case cellTemps(minC: Double, maxC: Double)
    case bmsPowerLimits(maxChargeKW: Double, maxDischargeKW: Double)
    case fastChargeStatus(active: Bool, powerKW: Double)
    case temps(ambientC: Double, cabinC: Double)
    case speedOdometer(speedMps: Double, odometerMi: Double)
    case fsdState(engaged: Bool)
    case preconditionState(PreconditionStatus)
}

public enum PandaConnectionState: Sendable, Equatable {
    case disconnected, probing, streaming, lost(since: Date)
}

/// Wi-Fi Panda/CAN client for the Enhance Auto S3XY Commander.
///
/// Protocol (comma.ai WiFi-Panda lineage — VERIFY against actual Commander
/// firmware in Phase 0 probe mode, see docs §4.1):
///  - UDP to 192.168.4.1:1338; any datagram acts as a heartbeat that
///    subscribes our addr:port to the CAN broadcast for ~5 s.
///  - Inbound datagrams contain repeated 16-byte records:
///    [rir: u32 LE | rdtr: u32 LE | data: 8 B]
///    address = rir >> 21 (11-bit) or rir >> 3 (29-bit, if rir & 4)
///    dlc     = rdtr & 0xF, bus = (rdtr >> 4) & 0xFF
///
/// RX-ONLY BY DESIGN: this client never transmits CAN frames. Heartbeats are
/// empty datagrams. See docs §4.1 for the safety rationale.
public actor PandaClient {
    public static let defaultEndpoint = NWEndpoint.hostPort(host: "192.168.4.1", port: 1338)

    private var connection: NWConnection?
    private var heartbeatTask: Task<Void, Never>?
    private var state: PandaConnectionState = .disconnected
    private let decoder = CANDecoder()

    private var continuation: AsyncStream<CANSignal>.Continuation?
    public private(set) var signals: AsyncStream<CANSignal>!

    private var stateContinuation: AsyncStream<PandaConnectionState>.Continuation?
    public private(set) var connectionStates: AsyncStream<PandaConnectionState>!

    /// Field-probe telemetry: enough to verify framing + IDs from the phone
    /// while sitting in the car on the Commander's Wi-Fi.
    public struct AddressCount: Sendable, Identifiable {
        public var address: UInt32
        public var count: Int
        public var id: UInt32 { address }
    }
    public struct BridgeStats: Sendable {
        public var state: PandaConnectionState = .disconnected
        public var datagrams = 0
        public var frames = 0
        public var decodedSignals = 0
        public var topAddresses: [AddressCount] = []
        public var lastFrameAt: Date?
        public init() {}
    }
    private var datagramCount = 0
    private var frameCount = 0
    private var signalCount = 0
    private var addressCounts: [UInt32: Int] = [:]

    public func currentStats() -> BridgeStats {
        var stats = BridgeStats()
        stats.state = state
        stats.datagrams = datagramCount
        stats.frames = frameCount
        stats.decodedSignals = signalCount
        stats.lastFrameAt = lastFrameAt == .distantPast ? nil : lastFrameAt
        stats.topAddresses = addressCounts
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { AddressCount(address: $0.key, count: $0.value) }
        return stats
    }

    /// CAN IDs to subscribe to — the Commander forwards ONLY these. Covers
    /// every ID the decoder understands (pack V/A, SOC, energy, cell temps,
    /// BMS limits). Extend alongside CANDecoder.
    public static let subscribeIDs: [UInt32] = [0x132, 0x292, 0x352, 0x312, 0x252]

    public init() {
        signals = AsyncStream { self.continuation = $0 }
        connectionStates = AsyncStream { self.stateContinuation = $0 }
    }

    /// Commander Panda subscription packet: 0x0f header, then [0xff, idHi, idLo]
    /// per CAN ID (max 43 per datagram — our list is far smaller).
    static func subscribePacket(ids: [UInt32]) -> Data {
        var packet = Data([0x0f])
        for id in ids {
            packet.append(0xff)
            packet.append(UInt8((id >> 8) & 0xFF))
            packet.append(UInt8(id & 0xFF))
        }
        return packet
    }

    private static let handshake = Data("ehllo".utf8)

    public func start(endpoint: NWEndpoint = PandaClient.defaultEndpoint) {
        guard connection == nil else { return }
        datagramCount = 0; frameCount = 0; signalCount = 0; addressCounts = [:]
        setState(.probing)
        let params = NWParameters.udp
        // Prohibit cellular WITHOUT pinning .wifi: the .wifi requirement trips
        // iOS's Local Network gate and yields ENETDOWN even when allowed
        // (proven by the field probe — POSIX/unpinned reached the host, pinned
        // did not).
        params.prohibitedInterfaceTypes = [.cellular]
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] nwState in
            Task { await self?.handleNWState(nwState) }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receiveLoop(conn)
        // "ehllo" every 1 s keeps the session alive (Commander drops it after
        // 5 s of silence) and doubles as the liveness probe.
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendHeartbeat()
                try? await Task.sleep(for: .seconds(1))
                await self?.checkLiveness()
            }
        }
    }

    public func stop() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        connection?.cancel(); connection = nil
        setState(.disconnected)
    }

    // MARK: - internals

    private var lastFrameAt: Date = .distantPast

    private func handleNWState(_ s: NWConnection.State) {
        if case .failed = s { restartSoon() }
        if case .waiting = s { setState(.lost(since: .init())) }
    }

    private func sendHeartbeat() {
        connection?.send(content: Self.handshake, completion: .idempotent)
    }

    private func sendSubscription() {
        connection?.send(content: Self.subscribePacket(ids: Self.subscribeIDs),
                         completion: .idempotent)
    }

    private func checkLiveness() {
        if state == .streaming, Date().timeIntervalSince(lastFrameAt) > 6 {
            setState(.lost(since: lastFrameAt))
        }
    }

    private func restartSoon() {
        let endpoint = connection?.endpoint ?? Self.defaultEndpoint
        stop()
        Task {
            try? await Task.sleep(for: .seconds(3))
            self.start(endpoint: endpoint)
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            Task {
                guard let self else { return }
                if let data { await self.ingest(datagram: data) }
                if error == nil { await self.receiveLoop(conn) } else { await self.restartSoon() }
            }
        }
    }

    private func ingest(datagram: Data) {
        lastFrameAt = .init()
        datagramCount += 1
        for frame in Self.parseRecords(datagram) {
            // Panda ACK (bus 15, frame 6): our cue to (re)send the CAN-ID
            // subscription. Until we do, the Commander streams nothing.
            if frame.bus == 15 && frame.address == 6 {
                sendSubscription()
                continue
            }
            frameCount += 1
            addressCounts[frame.address, default: 0] += 1
            if state != .streaming { setState(.streaming) }
            for signal in decoder.decode(frame) {
                signalCount += 1
                continuation?.yield(signal)
            }
        }
    }

    private func setState(_ s: PandaConnectionState) {
        state = s
        stateContinuation?.yield(s)
    }

    /// Parse the 16-byte Panda record framing. Tolerant of trailing garbage.
    static func parseRecords(_ data: Data) -> [CANFrame] {
        var frames: [CANFrame] = []
        var offset = data.startIndex
        while data.endIndex - offset >= 16 {
            let rir = data.readLEUInt32(at: offset)
            let rdtr = data.readLEUInt32(at: offset + 4)
            let extended = rir & 0x4 != 0
            let address = extended ? rir >> 3 : rir >> 21
            let dlc = Int(rdtr & 0xF)
            let bus = UInt8((rdtr >> 4) & 0xFF)
            let payload = data.subdata(in: (offset + 8)..<(offset + 8 + min(8, dlc)))
            frames.append(CANFrame(address: address, bus: bus, data: payload, receivedAt: .init()))
            offset += 16
        }
        return frames
    }
}

/// Model 3 CAN decode, signal layouts taken from the community DBC
/// (joshwardell/model3dbc). Intel/little-endian bit fields extracted via
/// `signalLE`; scales/offsets match the DBC exactly.
struct CANDecoder: Sendable {
    /// Extract a little-endian (Intel @1) signal: `length` bits at `start`,
    /// optionally two's-complement signed.
    static func signalLE(_ data: Data, start: Int, length: Int, signed: Bool = false) -> Int64 {
        var raw: UInt64 = 0
        for i in 0..<8 where data.startIndex + i < data.endIndex {
            raw |= UInt64(data[data.startIndex + i]) << (8 * i)
        }
        let mask: UInt64 = length >= 64 ? ~0 : ((UInt64(1) << length) - 1)
        let value = (raw >> UInt64(start)) & mask
        if signed, length < 64, value & (UInt64(1) << UInt64(length - 1)) != 0 {
            return Int64(bitPattern: value | ~mask)
        }
        return Int64(bitPattern: value)
    }

    func decode(_ f: CANFrame) -> [CANSignal] {
        let d = f.data
        func sig(_ start: Int, _ len: Int, signed: Bool = false) -> Double {
            Double(Self.signalLE(d, start: start, length: len, signed: signed))
        }
        switch f.address {
        case 0x132: // 306 HVBattAmpVolt
            guard d.count >= 4 else { return [] }
            let volts = sig(0, 16) * 0.01                       // BattVoltage132
            let amps = sig(16, 16, signed: true) * -0.1         // SmoothBattCurrent132
            return [.packVoltAmp(volts: volts, amps: amps)]
        case 0x292: // 658 BMS_SOC — SOCUI/min/max, 10-bit, 0.1%
            guard d.count >= 5 else { return [] }
            return [.soc(uiPercent: sig(10, 10) * 0.1,
                         minPercent: sig(0, 10) * 0.1,
                         maxPercent: sig(20, 10) * 0.1)]
        case 0x352: // 850 BMS_energyStatus — nominal full/remaining, 11-bit, 0.1 kWh
            guard d.count >= 8 else { return [] }
            return [.energyStatus(remainingKWh: sig(11, 11) * 0.1,
                                  fullKWh: sig(0, 11) * 0.1)]
        case 0x312: // 786 BMSthermal — min/max pack temp, 9-bit, 0.25 °C, −25 offset
            guard d.count >= 8 else { return [] }
            return [.cellTemps(minC: sig(44, 9) * 0.25 - 25,
                               maxC: sig(53, 9) * 0.25 - 25)]
        case 0x252: // 594 BMS_powerAvailable
            guard d.count >= 4 else { return [] }
            let regen = sig(0, 16) * 0.01                       // maxRegenPower
            let discharge = sig(16, 16) * 0.013                 // maxDischargePower
            return [.bmsPowerLimits(maxChargeKW: regen, maxDischargeKW: discharge)]
        default:
            return []
        }
    }
}

extension Data {
    func readLEUInt32(at index: Data.Index) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[index + $1]) << (8 * $1) }
    }
    func readLEUInt16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
}
