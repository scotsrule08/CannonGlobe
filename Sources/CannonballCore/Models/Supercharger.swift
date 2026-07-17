import Foundation
import CoreLocation

public enum SuperchargerVersion: String, Codable, Sendable {
    case v2urban   // 72 kW, never planned
    case v2        // 150 kW, paired-stall power sharing
    case v3        // 250 kW cabinets
    case v4stall   // V4 posts on V3 cabinets
    case v4cabinet // ≥325 kW true V4

    /// Per-car cap before vehicle limits.
    public var perCarCapKW: Double {
        switch self {
        case .v2urban: 72
        case .v2: 150
        case .v3, .v4stall: 250
        case .v4cabinet: 325
        }
    }
    public var hasPairedStalls: Bool { self == .v2 || self == .v2urban }
}

public enum Occupancy: Codable, Sendable, Equatable {
    case live(available: Int, total: Int, asOf: Date)   // Fleet nearby_charging_sites
    case predicted(fractionBusy: Double)                // historical prior
    case unknown

    /// Probability of waiting for a stall on arrival.
    public func waitProbability(totalStalls: Int) -> Double {
        switch self {
        case .live(let available, _, _): available > 0 ? 0 : 0.9
        case .predicted(let f): max(0, (f - 0.85) * 6)  // queues emerge near full
        case .unknown: 0.1
        }
    }
}

public struct Supercharger: Codable, Sendable, Identifiable {
    public var id: String                     // stable id (supercharge.info locationId)
    public var name: String
    public var coordinate: CLLocationCoordinate2D
    public var version: SuperchargerVersion
    public var stallCount: Int
    /// Seconds of detour: leave-highway → site + site → rejoin-highway, per direction.
    public var detourSecondsWestbound: Double
    public var detourSecondsEastbound: Double
    /// V2 only: stall label → paired stall label (1A ↔ 1B share a cabinet).
    public var pairingMap: [String: String]?
    public var occupancy: Occupancy
    /// 0–1 rolling health from watchdog history + community status (1 = healthy).
    public var healthScore: Double
    public var amenities: Set<String>         // "restroom", "food24h", ...
    /// Corridor position: route-miles from origin, for the DP ordering.
    public var routeMile: Double

    public init(id: String, name: String, coordinate: CLLocationCoordinate2D,
                version: SuperchargerVersion, stallCount: Int,
                detourSecondsWestbound: Double, detourSecondsEastbound: Double,
                pairingMap: [String: String]? = nil, occupancy: Occupancy = .unknown,
                healthScore: Double = 1.0, amenities: Set<String> = [], routeMile: Double) {
        self.id = id; self.name = name; self.coordinate = coordinate
        self.version = version; self.stallCount = stallCount
        self.detourSecondsWestbound = detourSecondsWestbound
        self.detourSecondsEastbound = detourSecondsEastbound
        self.pairingMap = pairingMap; self.occupancy = occupancy
        self.healthScore = healthScore; self.amenities = amenities
        self.routeMile = routeMile
    }
}
