import Foundation
import CoreLocation

/// Bundled corridor snapshot: Redball Garage → Portofino Hotel via
/// I-78 / PA Turnpike (I-76) / I-70 / I-15 / I-10.
///
/// ⚠️ SEED DATA — coordinates, route miles, stall counts, versions, and detour
/// times are APPROXIMATE placeholders for development and simulation. The
/// Phase-0 pre-run task regenerates this table from supercharge.info + a real
/// routing pass and hand-verifies every plausible stop (docs §4.3). The app
/// must never run the actual cannonball on unverified seed rows — every site
/// carries `verified: false` until the pre-run pass flips it.
public enum CorridorSeed {
    public static let originName = "Redball Garage, 538 W 22nd St, Manhattan"
    public static let destinationName = "Portofino Hotel, Redondo Beach"
    public static let destinationMile = 2790.0

    public struct SeedSite: Sendable {
        public var id: String
        public var name: String
        public var lat: Double, lon: Double
        public var routeMile: Double
        public var version: SuperchargerVersion
        public var stalls: Int
        public var verified: Bool
    }

    public static let sites: [SeedSite] = [
        .init(id: "edison-nj", name: "Edison, NJ", lat: 40.55, lon: -74.34, routeMile: 30, version: .v3, stalls: 20, verified: false),
        .init(id: "allentown-pa", name: "Allentown, PA", lat: 40.59, lon: -75.51, routeMile: 95, version: .v3, stalls: 16, verified: false),
        .init(id: "harrisburg-pa", name: "Harrisburg, PA", lat: 40.28, lon: -76.65, routeMile: 175, version: .v3, stalls: 16, verified: false),
        .init(id: "bedford-pa", name: "Bedford, PA", lat: 40.02, lon: -78.51, routeMile: 275, version: .v2, stalls: 8, verified: false),
        .init(id: "newstanton-pa", name: "New Stanton, PA", lat: 40.22, lon: -79.61, routeMile: 345, version: .v3, stalls: 12, verified: false),
        .init(id: "triadelphia-wv", name: "Triadelphia, WV", lat: 40.06, lon: -80.61, routeMile: 410, version: .v3, stalls: 8, verified: false),
        .init(id: "zanesville-oh", name: "Zanesville, OH", lat: 39.95, lon: -82.00, routeMile: 480, version: .v3, stalls: 12, verified: false),
        .init(id: "columbus-oh", name: "Columbus (Grove City), OH", lat: 39.88, lon: -83.06, routeMile: 540, version: .v3, stalls: 16, verified: false),
        .init(id: "dayton-oh", name: "Dayton (Huber Heights), OH", lat: 39.84, lon: -84.12, routeMile: 610, version: .v3, stalls: 12, verified: false),
        .init(id: "indianapolis-in", name: "Indianapolis, IN", lat: 39.77, lon: -86.06, routeMile: 715, version: .v3, stalls: 16, verified: false),
        .init(id: "terrehaute-in", name: "Terre Haute, IN", lat: 39.44, lon: -87.33, routeMile: 790, version: .v3, stalls: 12, verified: false),
        .init(id: "effingham-il", name: "Effingham, IL", lat: 39.13, lon: -88.56, routeMile: 870, version: .v3, stalls: 16, verified: false),
        .init(id: "stcharles-mo", name: "St. Charles, MO", lat: 38.78, lon: -90.55, routeMile: 975, version: .v3, stalls: 16, verified: false),
        .init(id: "columbia-mo", name: "Columbia, MO", lat: 38.96, lon: -92.33, routeMile: 1080, version: .v3, stalls: 12, verified: false),
        .init(id: "topeka-ks", name: "Topeka, KS", lat: 39.02, lon: -95.76, routeMile: 1265, version: .v3, stalls: 12, verified: false),
        .init(id: "salina-ks", name: "Salina, KS", lat: 38.88, lon: -97.61, routeMile: 1390, version: .v3, stalls: 16, verified: false),
        .init(id: "hays-ks", name: "Hays, KS", lat: 38.88, lon: -99.32, routeMile: 1485, version: .v3, stalls: 8, verified: false),
        .init(id: "colby-ks", name: "Colby, KS", lat: 39.39, lon: -101.05, routeMile: 1590, version: .v3, stalls: 12, verified: false),
        .init(id: "limon-co", name: "Limon, CO", lat: 39.26, lon: -103.69, routeMile: 1750, version: .v3, stalls: 12, verified: false),
        .init(id: "aurora-co", name: "Aurora (Denver), CO", lat: 39.71, lon: -104.82, routeMile: 1830, version: .v3, stalls: 24, verified: false),
        .init(id: "silverthorne-co", name: "Silverthorne, CO", lat: 39.63, lon: -106.07, routeMile: 1905, version: .v3, stalls: 16, verified: false),
        .init(id: "glenwood-co", name: "Glenwood Springs, CO", lat: 39.55, lon: -107.34, routeMile: 1995, version: .v3, stalls: 12, verified: false),
        .init(id: "grandjunction-co", name: "Grand Junction, CO", lat: 39.09, lon: -108.60, routeMile: 2080, version: .v3, stalls: 12, verified: false),
        .init(id: "greenriver-ut", name: "Green River, UT", lat: 38.99, lon: -110.16, routeMile: 2180, version: .v3, stalls: 8, verified: false),
        .init(id: "richfield-ut", name: "Richfield, UT", lat: 38.77, lon: -112.08, routeMile: 2295, version: .v3, stalls: 12, verified: false),
        .init(id: "beaver-ut", name: "Beaver, UT", lat: 38.25, lon: -112.65, routeMile: 2360, version: .v3, stalls: 12, verified: false),
        .init(id: "stgeorge-ut", name: "St. George, UT", lat: 37.10, lon: -113.55, routeMile: 2470, version: .v3, stalls: 16, verified: false),
        .init(id: "lasvegas-nv", name: "Las Vegas, NV", lat: 36.10, lon: -115.17, routeMile: 2590, version: .v3, stalls: 24, verified: false),
        .init(id: "baker-ca", name: "Baker, CA", lat: 35.27, lon: -116.07, routeMile: 2680, version: .v4stall, stalls: 40, verified: false),
        .init(id: "barstow-ca", name: "Barstow, CA", lat: 34.89, lon: -117.04, routeMile: 2745, version: .v3, stalls: 16, verified: false),
    ]

    /// Materialize seeds as `Supercharger` models with default detour costs.
    public static func superchargers() -> [Supercharger] {
        sites.map { s in
            Supercharger(
                id: s.id, name: s.name,
                coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
                version: s.version, stallCount: s.stalls,
                detourSecondsWestbound: 240, detourSecondsEastbound: 240,
                occupancy: .unknown,
                healthScore: s.verified ? 1.0 : 0.95,   // mild penalty until verified
                routeMile: s.routeMile)
        }
    }
}
