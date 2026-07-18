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

        let udp = await attempt(host: host, port: 1338, tcp: false,
                                payload: Data([0x00]), settle: 2.5)
        results.append(describe("UDP 1338 (Panda)", udp))

        for (port, sendATI) in [(UInt16(35000), true), (3333, true), (1338, false), (23, false)] {
            let r = await attempt(host: host, port: port, tcp: true,
                                  payload: sendATI ? Data("ATI\r".utf8) : nil, settle: 2.5)
            results.append(describe("TCP \(port)\(sendATI ? " (ELM327 ATI)" : "")", r))
        }

        results.append(await probeHTTP(host: host))
        return results
    }

    // MARK: - internals

    private static func describe(_ label: String, _ r: (connected: Bool, reply: Data?)) -> Result {
        if let reply = r.reply, !reply.isEmpty {
            return Result(label: label, outcome: "reply: \(preview(reply))", success: true)
        }
        if r.connected {
            return Result(label: label, outcome: "accepts connection, no data", success: true)
        }
        return Result(label: label, outcome: "no response", success: false)
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

    private static func attempt(host: String, port: UInt16, tcp: Bool,
                                payload: Data?, settle: Double) async
        -> (connected: Bool, reply: Data?) {
        await withCheckedContinuation { continuation in
            let params: NWParameters = tcp ? .tcp : .udp
            params.requiredInterfaceType = .wifi
            let conn = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(host),
                              port: NWEndpoint.Port(rawValue: port)!),
                using: params)
            let lock = NSLock()
            var finished = false
            func finish(_ connected: Bool, _ data: Data?) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                conn.cancel()
                continuation.resume(returning: (connected, data))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let payload {
                        conn.send(content: payload, completion: .idempotent)
                    }
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                        finish(true, data)
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + settle) {
                        finish(true, nil)
                    }
                case .failed, .cancelled:
                    finish(false, nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                finish(false, nil)
            }
        }
    }

    private static func probeHTTP(host: String) async -> Result {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
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
}
