import Foundation
import Network

/// One-shot transport prober for the CAN bridge: tries every plausible way
/// the Commander could be speaking and reports what answered. Adapter-level
/// only — the single "ATI\r" identification string goes to the adapter
/// firmware, never onto the car's CAN bus.
public enum BridgeProbe {
    public struct Result: Sendable, Identifiable {
        public var label: String
        public var outcome: String
        public var success: Bool
        public var id: String { label }
    }

    public static func run(host: String) async -> [Result] {
        var results: [Result] = []

        // Ground truth first: are we even ON the bridge's network?
        if let ip = wifiIPv4() {
            results.append(Result(label: "Phone Wi-Fi",
                                  outcome: "en0 has \(ip)",
                                  success: ip.hasPrefix("192.168.4.")))
        } else {
            results.append(Result(label: "Phone Wi-Fi",
                                  outcome: "no Wi-Fi IPv4 — phone fell back to cellular?",
                                  success: false))
        }

        // Passive: some bridges just broadcast CAN over UDP.
        results.append(await listenUDP(port: 1338, seconds: 4))

        let udp = await attempt(host: host, port: 1338, tcp: false,
                                payload: Data([0x00]), settle: 2.5)
        results.append(describe("UDP 1338 (Panda)", udp))

        for (port, sendATI) in [(UInt16(35000), true), (3333, true), (2323, true),
                                (1338, false), (8080, false), (23, false)] {
            let r = await attempt(host: host, port: port, tcp: true,
                                  payload: sendATI ? Data("ATI\r".utf8) : nil, settle: 2.5)
            results.append(describe("TCP \(port)\(sendATI ? " (ELM327 ATI)" : "")", r))
        }

        results.append(await probeHTTP(host: host))
        return results
    }

    // MARK: - internals

    private static func describe(_ label: String,
                                 _ r: (connected: Bool, reply: Data?, note: String?)) -> Result {
        if let reply = r.reply, !reply.isEmpty {
            return Result(label: label, outcome: "reply: \(preview(reply))", success: true)
        }
        if r.connected {
            return Result(label: label, outcome: "accepts connection, no data", success: true)
        }
        return Result(label: label, outcome: r.note ?? "no response", success: false)
    }

    private static func preview(_ data: Data) -> String {
        let slice = data.prefix(48)
        let printable = slice.allSatisfy { $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }
        if printable, let text = String(data: slice, encoding: .ascii) {
            let cleaned = text.replacingOccurrences(of: "\r", with: "␍")
                .replacingOccurrences(of: "\n", with: "␊")
            return "\"\(cleaned)\""
        }
        return slice.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
            + (data.count > 20 ? "…" : "")
    }

    private static func note(for error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED): return "refused — host ALIVE, port closed"
        case .posix(.EHOSTUNREACH): return "host unreachable"
        case .posix(.ENETUNREACH): return "network unreachable (wrong Wi-Fi?)"
        case .posix(.ETIMEDOUT): return "timed out"
        case .posix(.ENETDOWN):
            return "BLOCKED by iOS Local Network permission — allow CannonGlobe in Settings"
        default: return "failed: \(error.localizedDescription)"
        }
    }

    private static func attempt(host: String, port: UInt16, tcp: Bool,
                                payload: Data?, settle: Double) async
        -> (connected: Bool, reply: Data?, note: String?) {
        await withCheckedContinuation { continuation in
            let params: NWParameters = tcp ? .tcp : .udp
            params.requiredInterfaceType = .wifi
            let conn = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(host),
                              port: NWEndpoint.Port(rawValue: port)!),
                using: params)
            let lock = NSLock()
            var finished = false
            func finish(_ connected: Bool, _ data: Data?, _ note: String?) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                conn.cancel()
                continuation.resume(returning: (connected, data, note))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let payload {
                        conn.send(content: payload, completion: .idempotent)
                    }
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                        finish(true, data, nil)
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + settle) {
                        finish(true, nil, nil)
                    }
                case .waiting(let error):
                    // NW retries forever on refused; surface it and stop.
                    finish(false, nil, note(for: error))
                case .failed(let error):
                    finish(false, nil, note(for: error))
                case .cancelled:
                    finish(false, nil, nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                finish(false, nil, "timed out")
            }
        }
    }

    private static func listenUDP(port: UInt16, seconds: Double) async -> Result {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ r: Result) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: r)
            }
            guard let listener = try? NWListener(using: .udp,
                                                 on: NWEndpoint.Port(rawValue: port)!) else {
                finish(Result(label: "UDP \(port) listen", outcome: "couldn't bind", success: false))
                return
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receiveMessage { data, _, _, _ in
                    let from = "\(conn.endpoint)"
                    let outcome = data.map { "broadcast from \(from): \(preview($0))" }
                        ?? "traffic from \(from)"
                    listener.cancel(); conn.cancel()
                    finish(Result(label: "UDP \(port) listen", outcome: outcome, success: true))
                }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                listener.cancel()
                finish(Result(label: "UDP \(port) listen",
                              outcome: "no broadcast heard", success: false))
            }
        }
    }

    private static func probeHTTP(host: String) async -> Result {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.allowsCellularAccess = false
        let session = URLSession(configuration: config)
        guard let url = URL(string: "http://\(host)/") else {
            return Result(label: "HTTP 80", outcome: "bad host", success: false)
        }
        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data.prefix(120), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "\(data.count) bytes"
            return Result(label: "HTTP 80", outcome: "HTTP \(code): \(body)", success: true)
        } catch {
            return Result(label: "HTTP 80", outcome: "no response", success: false)
        }
    }

    /// The phone's Wi-Fi (en0) IPv4 — proves association with the bridge's
    /// subnet independent of any permission gates.
    static func wifiIPv4() -> String? {
        var result: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
            }
        }
        return result
    }
}
