import Foundation

/// Subset of Tessie/Fleet vehicle state the fusion layer consumes.
public struct CloudVehicleState: Sendable, Codable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var speedMph: Double?
    public var socPercent: Double
    public var ratedRangeMi: Double
    public var chargingState: String          // "Charging", "Supercharging", ...
    public var chargerPowerKW: Double?
    public var insideTempC: Double?
    public var outsideTempC: Double?
    public var batteryHeaterOn: Bool?
    public var activeRouteDestination: String?
    public var activeRouteMinutesToArrival: Double?
}

public struct NearbyChargingSite: Sendable, Codable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var availableStalls: Int
    public var totalStalls: Int
    public var siteClosed: Bool
}

public enum TessieError: Error, LocalizedError {
    case http(Int), rateLimited(retryAfter: TimeInterval), decoding

    public var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "Unauthorized — check the API token"
        case .http(404): return "Vehicle not found — check the VIN"
        case .http(let code): return "HTTP \(code)"
        case .rateLimited: return "Rate limited, backing off"
        case .decoding: return "Unexpected response format"
        }
    }
}

/// Tessie REST + streaming client with a rate-limit governor.
/// Tessie mirrors Fleet API vehicle-data and adds history endpoints; the same
/// protocol shape lets a direct Fleet API client swap in (docs §4.2).
public actor TessieClient {
    private var vin: String
    private var token: String
    private let base = URL(string: "https://api.tessie.com")!
    private let session: URLSession

    /// Governor: no more than one REST poll per 15 s; cached reads otherwise.
    private var lastPoll: Date = .distantPast
    private var cached: CloudVehicleState?
    private let minPollInterval: TimeInterval = 15

    private var streamContinuation: AsyncStream<CloudVehicleState>.Continuation?
    public private(set) var updates: AsyncStream<CloudVehicleState>!

    public struct ConnectionStatus: Sendable {
        public var streamingConnected = false
        public var lastUpdate: Date?
        public var lastError: String?
        public init() {}
    }
    private var status = ConnectionStatus()
    public func currentStatus() -> ConnectionStatus { status }

    private var activeSocket: URLSessionWebSocketTask?

    public init(vin: String, token: String, session: URLSession = .shared) {
        self.vin = vin; self.token = token; self.session = session
        updates = AsyncStream { self.streamContinuation = $0 }
    }

    public var hasCredentials: Bool { !vin.isEmpty && !token.isEmpty }

    /// Swap credentials at runtime (in-app settings). The next poll and the
    /// next streaming reconnect pick them up; the cache is invalidated so the
    /// first read after a change is always fresh.
    public func updateCredentials(vin: String, token: String) {
        self.vin = vin; self.token = token
        cached = nil
        lastPoll = .distantPast
        status = ConnectionStatus()
        // Drop the live socket; the streaming loop reconnects with new creds.
        activeSocket?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: REST

    public func state(forceFresh: Bool = false) async throws -> CloudVehicleState {
        if !forceFresh, let cached, Date().timeIntervalSince(lastPoll) < minPollInterval {
            return cached
        }
        let useCache = Date().timeIntervalSince(lastPoll) < 60 && !forceFresh
        let url = base.appending(path: "\(vin)/state")
            .appending(queryItems: [.init(name: "use_cache", value: useCache ? "true" : "false")])
        do {
            let fresh = try await get(url, as: TessieStateDTO.self).toCloudState()
            lastPoll = .init(); cached = fresh
            status.lastUpdate = .init(); status.lastError = nil
            streamContinuation?.yield(fresh)
            return fresh
        } catch {
            status.lastError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            throw error
        }
    }

    /// Live stall availability via Fleet `nearby_charging_sites` (mirrored).
    public func nearbyChargingSites() async throws -> [NearbyChargingSite] {
        try await get(base.appending(path: "\(vin)/nearby_charging_sites"),
                      as: NearbySitesDTO.self).superchargers
    }

    // MARK: Commands (the ToS-clean levers we use — docs §4.2)

    /// Share a destination to the car; navigating to a Supercharger triggers
    /// on-route battery preconditioning. This is the primary precondition lever.
    public func shareDestination(_ query: String) async throws {
        try await post(base.appending(path: "\(vin)/command/share"),
                       body: ["value": query])
    }

    public func setChargeLimit(percent: Int) async throws {
        try await post(base.appending(path: "\(vin)/command/set_charge_limit"),
                       body: ["percent": String(percent)])
    }

    /// Stall identification at night: flash lights.
    public func flashLights() async throws {
        try await post(base.appending(path: "\(vin)/command/flash"), body: [:])
    }

    // MARK: Streaming — Tessie fleet-telemetry WebSocket at
    // wss://streaming.tessie.com/{VIN}, JSON key/value data messages
    // (developer.tessie.com/reference/access-tesla-fleet-telemetry).
    // A 30 s REST poll runs alongside as a safety net and to seed the
    // first full snapshot the telemetry deltas merge into.

    public func startStreaming() {
        Task {
            while !Task.isCancelled {
                guard hasCredentials else {                          // idle until configured
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                do { try await streamOnce() }
                catch {
                    status.streamingConnected = false
                    if status.lastError == nil {
                        status.lastError = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                    try? await Task.sleep(for: .seconds(10))        // reconnect w/ backoff
                }
            }
        }
        Task {
            while !Task.isCancelled {
                if hasCredentials { _ = try? await state() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func streamOnce() async throws {
        var comps = URLComponents(string: "wss://streaming.tessie.com/\(vin)")!
        comps.queryItems = [.init(name: "access_token", value: token)]
        let socket = session.webSocketTask(with: comps.url!)
        socket.resume()
        activeSocket = socket
        defer {
            activeSocket = nil
            socket.cancel(with: .goingAway, reason: nil)
        }
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data?
            switch message {
            case .data(let d): data = d
            case .string(let s): data = s.data(using: .utf8)
            @unknown default: data = nil
            }
            guard let data,
                  let telemetry = try? JSONDecoder().decode(TelemetryMessage.self, from: data),
                  let fields = telemetry.data, !fields.isEmpty else { continue }
            status.streamingConnected = true
            apply(telemetry: fields)
        }
    }

    /// Merge fleet-telemetry deltas into the last full snapshot. Until REST
    /// has seeded one, kick a poll instead of emitting a partial state.
    private func apply(telemetry fields: [TelemetryMessage.Datum]) {
        guard var merged = cached else {
            Task { _ = try? await state(forceFresh: true) }
            return
        }
        for field in fields {
            let v = field.value
            switch field.key {
            case "Soc": if let n = v.number { merged.socPercent = n }
            case "Location": if let loc = v.location {
                merged.latitude = loc.latitude; merged.longitude = loc.longitude
            }
            case "VehicleSpeed": if let n = v.number { merged.speedMph = n }
            case "RatedRange", "IdealBatteryRange":
                if let n = v.number { merged.ratedRangeMi = n }
            case "OutsideTemp": if let n = v.number { merged.outsideTempC = n }
            case "InsideTemp": if let n = v.number { merged.insideTempC = n }
            case "DCChargingPower": if let n = v.number, n > 0 { merged.chargerPowerKW = n }
            case "ACChargingPower": if let n = v.number, n > 0 { merged.chargerPowerKW = n }
            case "BatteryHeaterOn": if let b = v.bool { merged.batteryHeaterOn = b }
            case "DetailedChargeState": if let s = v.string {
                merged.chargingState = s.contains("Charging")
                    ? (merged.chargerPowerKW ?? 0 > 20 ? "Supercharging" : "Charging")
                    : "Disconnected"
            }
            default: break
            }
        }
        merged.timestamp = .init()
        cached = merged
        status.lastUpdate = .init(); status.lastError = nil
        streamContinuation?.yield(merged)
    }

    // MARK: plumbing

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 429 {
            let retry = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw TessieError.rateLimited(retryAfter: retry)
        }
        guard code == 200 else { throw TessieError.http(code) }
        guard let decoded = try? JSONDecoder.tessie.decode(T.self, from: data) else {
            throw TessieError.decoding
        }
        return decoded
    }

    private func post(_ url: URL, body: [String: String]) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw TessieError.http(code) }
    }
}

// MARK: - Fleet-telemetry stream DTOs

struct TelemetryMessage: Decodable {
    struct Datum: Decodable {
        var key: String
        var value: TelemetryValue
    }
    var data: [Datum]?
}

/// Fleet telemetry wraps each value in a one-key object whose key names the
/// type (stringValue, doubleValue, locationValue, detailedChargeStateValue…).
/// Decode by scanning every key for the first primitive that fits.
struct TelemetryValue: Decodable {
    var string: String?
    var number: Double?
    var bool: Bool?
    var location: Location?
    struct Location: Decodable { var latitude: Double; var longitude: Double }

    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        for key in c.allKeys {
            if let loc = try? c.decode(Location.self, forKey: key) { location = loc }
            else if let d = try? c.decode(Double.self, forKey: key) { number = d }
            else if let b = try? c.decode(Bool.self, forKey: key) { bool = b }
            else if let s = try? c.decode(String.self, forKey: key) {
                string = s
                if number == nil { number = Double(s) }
                if bool == nil, s == "true" || s == "false" { bool = s == "true" }
            }
        }
    }
}

// MARK: - DTOs (field names per Tessie's mirrored Fleet vehicle-data schema)

struct TessieStateDTO: Decodable {
    struct DriveState: Decodable {
        var latitude: Double; var longitude: Double; var speed: Double?
        var activeRouteDestination: String?
        var activeRouteMinutesToArrival: Double?
    }
    struct ChargeState: Decodable {
        var batteryLevel: Double; var batteryRange: Double
        var chargingState: String; var chargerPower: Double?
        var batteryHeaterOn: Bool?
    }
    struct ClimateState: Decodable {
        var insideTemp: Double?; var outsideTemp: Double?
    }
    var driveState: DriveState
    var chargeState: ChargeState
    var climateState: ClimateState

    func toCloudState() -> CloudVehicleState {
        CloudVehicleState(
            timestamp: .init(),
            latitude: driveState.latitude, longitude: driveState.longitude,
            speedMph: driveState.speed,
            socPercent: chargeState.batteryLevel,
            ratedRangeMi: chargeState.batteryRange,
            chargingState: chargeState.chargingState,
            chargerPowerKW: chargeState.chargerPower,
            insideTempC: climateState.insideTemp, outsideTempC: climateState.outsideTemp,
            batteryHeaterOn: chargeState.batteryHeaterOn,
            activeRouteDestination: driveState.activeRouteDestination,
            activeRouteMinutesToArrival: driveState.activeRouteMinutesToArrival)
    }
}

struct NearbySitesDTO: Decodable { var superchargers: [NearbyChargingSite] }

extension JSONDecoder {
    static let tessie: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
