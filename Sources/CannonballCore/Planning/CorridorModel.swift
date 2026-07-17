import Foundation

/// Owns the offline corridor dataset (elevation samples + weather forecast
/// keyed by route mile) and builds `RouteLeg`s for the planner. Everything it
/// needs survives total connectivity loss (docs §2.3); weather refresh just
/// updates the arrays in place.
public actor CorridorModel {
    public struct MilePost: Sendable {
        public var mile: Double
        public var elevationM: Float
        public var headwindMps: Double
        public var crosswindMps: Double
        public var windSigmaMps: Double
        public var ambientC: Double
        public var trafficSpeedMps: Double   // traffic-adjusted attainable speed
        public init(mile: Double, elevationM: Float, headwindMps: Double = 0,
                    crosswindMps: Double = 0, windSigmaMps: Double = 1.5,
                    ambientC: Double = 20, trafficSpeedMps: Double = 31.3) {
            self.mile = mile; self.elevationM = elevationM
            self.headwindMps = headwindMps; self.crosswindMps = crosswindMps
            self.windSigmaMps = windSigmaMps; self.ambientC = ambientC
            self.trafficSpeedMps = trafficSpeedMps
        }
    }

    private var posts: [MilePost]              // sorted by mile, ~1-mi spacing
    public init(posts: [MilePost]) {
        self.posts = posts.sorted { $0.mile < $1.mile }
    }

    /// Flat-profile fallback for development/simulation before the elevation
    /// bake exists: 1-mi posts at 300 m elevation, 70 mph, calm air.
    public static func flatFallback(totalMiles: Double = CorridorSeed.destinationMile) -> CorridorModel {
        CorridorModel(posts: stride(from: 0.0, through: totalMiles, by: 1).map {
            MilePost(mile: $0, elevationM: 300)
        })
    }

    /// Apply a weather refresh: forecast rows keyed by route mile.
    public func applyWeather(_ rows: [(mile: Double, headwind: Double, crosswind: Double,
                                       sigma: Double, ambientC: Double)]) {
        guard !rows.isEmpty else { return }
        for i in posts.indices {
            // Nearest forecast row (rows are sparse, ~25-mi spacing).
            let nearest = rows.min { abs($0.mile - posts[i].mile) < abs($1.mile - posts[i].mile) }!
            posts[i].headwindMps = nearest.headwind
            posts[i].crosswindMps = nearest.crosswind
            posts[i].windSigmaMps = nearest.sigma
            posts[i].ambientC = nearest.ambientC
        }
    }

    public func applyTraffic(_ rows: [(mile: Double, speedMps: Double)]) {
        guard !rows.isEmpty else { return }
        for i in posts.indices {
            let nearest = rows.min { abs($0.mile - posts[i].mile) < abs($1.mile - posts[i].mile) }!
            posts[i].trafficSpeedMps = nearest.speedMps
        }
    }

    /// Leg between two route miles, aggregating posts into the RouteLeg shape.
    public func leg(from fromMile: Double, to toMile: Double,
                    fromID: String = "", toID: String = "") -> RouteLeg {
        let span = posts.filter { $0.mile >= fromMile && $0.mile <= toMile }
        let distance = toMile - fromMile
        guard span.count >= 2, distance > 0 else {
            return RouteLeg(fromSiteID: fromID, toSiteID: toID, distanceMi: max(0.1, distance),
                            elevation: ElevationProfile(stepMeters: 1609, elevationsM: [300, 300]),
                            wind: WindForecast(headwindMps: 0, crosswindMps: 0),
                            ambientTempC: 20, trafficDriveSeconds: max(1, distance / 70 * 3600),
                            avgSpeedMps: 31.3)
        }
        let meanSpeed = span.map(\.trafficSpeedMps).reduce(0, +) / Double(span.count)
        let driveSeconds = span.dropLast().reduce(0.0) { acc, post in
            acc + 1609.34 / max(5, post.trafficSpeedMps)
        }
        return RouteLeg(
            fromSiteID: fromID, toSiteID: toID, distanceMi: distance,
            elevation: ElevationProfile(stepMeters: 1609.34, elevationsM: span.map(\.elevationM)),
            wind: WindForecast(
                headwindMps: span.map(\.headwindMps).reduce(0, +) / Double(span.count),
                crosswindMps: span.map(\.crosswindMps).reduce(0, +) / Double(span.count),
                sigmaMps: span.map(\.windSigmaMps).max() ?? 1.5),
            ambientTempC: span.map(\.ambientC).reduce(0, +) / Double(span.count),
            trafficDriveSeconds: driveSeconds,
            avgSpeedMps: meanSpeed)
    }

    /// Snapshot leg builder for the (synchronous, Sendable) planner.
    public func legBuilderSnapshot() -> TripPlanner.LegBuilder {
        let snapshot = posts
        return { fromMile, toMile in
            // Duplicated aggregation over the captured snapshot keeps the
            // planner pure and detached from actor hops in its hot loop.
            let span = snapshot.filter { $0.mile >= fromMile && $0.mile <= toMile }
            let distance = toMile - fromMile
            guard span.count >= 2, distance > 0 else {
                return RouteLeg(fromSiteID: "", toSiteID: "", distanceMi: max(0.1, distance),
                                elevation: ElevationProfile(stepMeters: 1609, elevationsM: [300, 300]),
                                wind: WindForecast(headwindMps: 0, crosswindMps: 0),
                                ambientTempC: 20, trafficDriveSeconds: max(1, distance / 70 * 3600),
                                avgSpeedMps: 31.3)
            }
            let meanSpeed = span.map(\.trafficSpeedMps).reduce(0, +) / Double(span.count)
            let driveSeconds = span.dropLast().reduce(0.0) { acc, post in
                acc + 1609.34 / max(5, post.trafficSpeedMps)
            }
            return RouteLeg(
                fromSiteID: "", toSiteID: "", distanceMi: distance,
                elevation: ElevationProfile(stepMeters: 1609.34, elevationsM: span.map(\.elevationM)),
                wind: WindForecast(
                    headwindMps: span.map(\.headwindMps).reduce(0, +) / Double(span.count),
                    crosswindMps: span.map(\.crosswindMps).reduce(0, +) / Double(span.count),
                    sigmaMps: span.map(\.windSigmaMps).max() ?? 1.5),
                ambientTempC: span.map(\.ambientC).reduce(0, +) / Double(span.count),
                trafficDriveSeconds: driveSeconds,
                avgSpeedMps: meanSpeed)
        }
    }
}
