import Foundation

/// One EV charging station from the DOE Alternative Fuels Data Center.
public struct AFDCStation: Sendable, Identifiable, Decodable {
    public var id: Int
    public var stationName: String
    public var latitude: Double
    public var longitude: Double
    public var distance: Double?             // miles from the query point
    public var accessCode: String?           // "public" / "private"
    public var accessDaysTime: String?
    public var statusCode: String?           // E available, P planned, T temp down
    public var evDcFastNum: Int?
    public var evLevel2EvseNum: Int?
    public var evConnectorTypes: [String]?   // J1772, J1772COMBO, CHADEMO, TESLA…
    public var evNetwork: String?
    public var evPricing: String?
    public var streetAddress: String?
    public var city: String?
    public var state: String?

    public var isPublic: Bool { accessCode?.lowercased() == "public" }
    public var isAvailable: Bool { (statusCode ?? "E") == "E" }
    public var dcFastCount: Int { evDcFastNum ?? 0 }
    public var level2Count: Int { evLevel2EvseNum ?? 0 }

    /// Human connector names (NACS for Tesla, CCS for J1772COMBO).
    public var connectorNames: [String] {
        (evConnectorTypes ?? []).map {
            switch $0.uppercased() {
            case "TESLA": "NACS"
            case "J1772COMBO": "CCS"
            case "CHADEMO": "CHAdeMO"
            case "J1772": "J1772"
            default: $0
            }
        }
    }
}

/// DOE Alternative Fuels Data Center station finder (developer.nrel.gov).
/// DEMO_KEY works with tight rate limits (~30/hr); a free personal key from
/// developer.nrel.gov/signup removes them.
public enum AFDCClient {
    public struct Response: Decodable {
        public var totalResults: Int?
        public var fuelStations: [AFDCStation]
    }

    public enum ChargingLevel: String, CaseIterable, Sendable {
        case dcFast = "dc_fast"
        case all = ""
    }

    public static func nearest(latitude: Double, longitude: Double,
                               radiusMi: Double, level: ChargingLevel,
                               publicOnly: Bool, apiKey: String,
                               limit: Int = 100) async throws -> [AFDCStation] {
        var comps = URLComponents(string: "https://developer.nrel.gov/api/alt-fuel-stations/v1/nearest.json")!
        var items: [URLQueryItem] = [
            .init(name: "api_key", value: apiKey),
            .init(name: "fuel_type", value: "ELEC"),
            .init(name: "latitude", value: String(format: "%.5f", latitude)),
            .init(name: "longitude", value: String(format: "%.5f", longitude)),
            .init(name: "radius", value: String(format: "%.0f", radiusMi)),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "status", value: "E"),
        ]
        if level == .dcFast {
            items.append(.init(name: "ev_charging_level", value: level.rawValue))
        }
        if publicOnly {
            items.append(.init(name: "access", value: "public"))
        }
        comps.queryItems = items
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            if code == 429 { throw AFDCError.rateLimited }
            if code == 403 { throw AFDCError.badKey }
            throw AFDCError.http(code)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data).fuelStations
    }
}

public enum AFDCError: Error, LocalizedError {
    case rateLimited, badKey, http(Int)

    public var errorDescription: String? {
        switch self {
        case .rateLimited:
            "AFDC rate limit hit. Add a free NREL API key in Settings (developer.nrel.gov/signup)."
        case .badKey:
            "NREL API key rejected. Check it in Settings."
        case .http(let code):
            "AFDC request failed (HTTP \(code))."
        }
    }
}
