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

        // Unpinned NW attempt — rules out the .wifi interface requirement.
        let unpinned = await attempt(host: host, port: 35000, tcp: true,
                                     payload: Data("ATI\r".utf8), settle: 2.5,
                                     pinWiFi: false)
        results.append(describe("TCP 35000 (no iface pin)", unpinned))

        // Raw POSIX sockets bound to en0 — bypasses Network.framework path
        // logic entirely. If these work where NW fails, we build on POSIX.
        for (port, sendATI) in [(UInt16(35000), true), (3333, true)] {
            results.append(await posix {
                posixTCP(host: host, port: port,
                         payload: sendATI ? Data("ATI\r".utf8) : nil, timeout: 3)
            })
        }
        results.append(await posix { posixUDP(host: host, port: 1338, timeout: 3) })

        results.append(await probeHTTP(host: host))

        // Host is alive but the guessed ports are closed — sweep to find the
        // open one. POSIX, since that path is unblocked.
        results.append(await posix { posixPortSweep(host: host) })
        return results
    }

    /// Fast connect-scan of common OBD/CAN-bridge ports; reports which accept.
    static func posixPortSweep(host: String) -> Result {
        let ports: [UInt16] = [23, 80, 1000, 1338, 2000, 2323, 3000, 3333, 3500,
                               4000, 5000, 5555, 6000, 6969, 7000, 7070, 8000,
                               8080, 8081, 8888, 9000, 9999, 20000, 23000, 29536,
                               35000, 35001]
        var open: [UInt16] = []
        for port in ports {
            guard var addr = makeSockaddr(host: host, port: port) else { continue }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            bindToWiFi(fd)
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 {
                open.append(port)
            } else if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, 700) > 0 {
                    var soError: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                    if soError == 0 { open.append(port) }
                }
            }
            close(fd)
        }
        if open.isEmpty {
            return Result(label: "Port sweep",
                          outcome: "no open TCP ports found (BLE-only device?)",
                          success: false)
        }
        return Result(label: "Port sweep",
                      outcome: "OPEN: " + open.map(String.init).joined(separator: ", "),
                      success: true)
    }

    private static func posix(_ body: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
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
                                payload: Data?, settle: Double,
                                pinWiFi: Bool = true) async
        -> (connected: Bool, reply: Data?, note: String?) {
        await withCheckedContinuation { continuation in
            let params: NWParameters = tcp ? .tcp : .udp
            if pinWiFi { params.requiredInterfaceType = .wifi }
            params.prohibitedInterfaceTypes = [.cellular]
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

    // MARK: POSIX probes (bound to en0, bypassing Network.framework)

    private static func makeSockaddr(host: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    private static func bindToWiFi(_ fd: Int32) {
        var index = if_nametoindex("en0")
        guard index != 0 else { return }
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index,
                   socklen_t(MemoryLayout<UInt32>.size))
    }

    private static func errnoText(_ code: Int32) -> String {
        "\(String(cString: strerror(code))) (errno \(code))"
    }

    static func posixTCP(host: String, port: UInt16, payload: Data?,
                         timeout: Double) -> Result {
        let label = "POSIX TCP \(port)"
        guard var addr = makeSockaddr(host: host, port: port) else {
            return Result(label: label, outcome: "bad host", success: false)
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return Result(label: label, outcome: "socket: \(errnoText(errno))", success: false)
        }
        defer { close(fd) }
        bindToWiFi(fd)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 && errno != EINPROGRESS {
            return Result(label: label, outcome: "connect: \(errnoText(errno))", success: false)
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else {
            return Result(label: label, outcome: "connect timed out", success: false)
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard soError == 0 else {
            let hint = soError == ECONNREFUSED ? " — host ALIVE, port closed" : ""
            return Result(label: label, outcome: errnoText(soError) + hint,
                          success: soError == ECONNREFUSED)
        }
        if let payload {
            _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }
        }
        var rfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&rfd, 1, Int32(timeout * 1000)) > 0 {
            var buffer = [UInt8](repeating: 0, count: 512)
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                return Result(label: label,
                              outcome: "reply: \(preview(Data(buffer[0..<n])))",
                              success: true)
            }
        }
        return Result(label: label, outcome: "CONNECTED, no data", success: true)
    }

    static func posixUDP(host: String, port: UInt16, timeout: Double) -> Result {
        let label = "POSIX UDP \(port)"
        guard var addr = makeSockaddr(host: host, port: port) else {
            return Result(label: label, outcome: "bad host", success: false)
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            return Result(label: label, outcome: "socket: \(errnoText(errno))", success: false)
        }
        defer { close(fd) }
        bindToWiFi(fd)
        let heartbeat = Data([0x00])
        let sent = heartbeat.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, heartbeat.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else {
            return Result(label: label, outcome: "sendto: \(errnoText(errno))", success: false)
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, Int32(timeout * 1000)) > 0 {
            var buffer = [UInt8](repeating: 0, count: 2048)
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                return Result(label: label,
                              outcome: "reply: \(preview(Data(buffer[0..<n])))",
                              success: true)
            }
        }
        return Result(label: label, outcome: "sent, nothing back", success: false)
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
