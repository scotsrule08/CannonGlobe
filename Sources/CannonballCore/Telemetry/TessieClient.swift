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

public enum TessieError: Error { case http(Int), rateLimited(retryAfter: TimeInterval), decoding }

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
    }

    // MARK: REST

    public func state(forceFresh: Bool = false) async throws -> CloudVehicleState {
        if !forceFresh, let cached, Date().timeIntervalSince(lastPoll) < minPollInterval {
            return cached
        }
        let useCache = Date().timeIntervalSince(lastPoll) < 60 && !forceFresh
        let url = base.appending(path: "\(vin)/state")
            .appending(queryItems: [.init(name: "use_cache", value: useCache ? "true" : "false")])
        let fresh = try await get(url, as: TessieStateDTO.self).toCloudState()
        lastPoll = .init(); cached = fresh
        streamContinuation?.yield(fresh)
        return fresh
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

    // MARK: Streaming (SSE) — location/SOC/charger_power when off CAN.

    public func startStreaming() {
        Task {
            while !Task.isCancelled {
                guard hasCredentials else {                          // idle until configured
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                do { try await streamOnce() }
                catch { try? await Task.sleep(for: .seconds(10)) }  // reconnect w/ backoff
            }
        }
    }

    private func streamOnce() async throws {
        var req = URLRequest(url: base.appending(path: "\(vin)/stream"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TessieError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            if let data = line.dropFirst(5).data(using: .utf8),
               let dto = try? JSONDecoder.tessie.decode(TessieStateDTO.self, from: data) {
                let s = dto.toCloudState()
                cached = s
                streamContinuation?.yield(s)
            }
        }
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
