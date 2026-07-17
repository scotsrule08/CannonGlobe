import Foundation
import CoreLocation

/// A dynamically built charging corridor for an arbitrary road trip: the
/// route polyline with cumulative mileage, plus every open Supercharger
/// projected onto it. Generalizes the hardcoded `CorridorSeed` so the DP
/// planner works between any two points, not just the cannonball route.
public struct RouteCorridor: Sendable {
    public struct RoutePoint: Sendable {
        public var latitude: Double
        public var longitude: Double
        public var mile: Double
    }

    public var destinationName: String
    public var destinationMile: Double
    public var sites: [Supercharger]
    public var points: [RoutePoint]
    public var avgSpeedMps: Double
    /// (routeMile, elevationM) anchors — site elevations at build time,
    /// replaced by a dense terrain profile once ElevationClient returns.
    var elevationAnchors: [(Double, Double)]

    public struct WeatherAnchor: Sendable {
        public var mile: Double
        public var headwindMps: Double
        public var crosswindMps: Double
        public var sigmaMps: Double
        public var ambientC: Double
        public var precipMmPerHour: Double
        public init(mile: Double, headwindMps: Double, crosswindMps: Double,
                    sigmaMps: Double, ambientC: Double, precipMmPerHour: Double) {
            self.mile = mile; self.headwindMps = headwindMps
            self.crosswindMps = crosswindMps; self.sigmaMps = sigmaMps
            self.ambientC = ambientC; self.precipMmPerHour = precipMmPerHour
        }
    }
    /// Live forecast along the route; empty until the first weather refresh.
    public private(set) var weatherAnchors: [WeatherAnchor] = []

    public mutating func applyWeather(_ anchors: [WeatherAnchor]) {
        weatherAnchors = anchors.sorted { $0.mile < $1.mile }
    }

    /// Swap in a dense terrain profile (mile, elevationM), replacing the
    /// site-interpolated anchors.
    public mutating func applyElevation(_ anchors: [(Double, Double)]) {
        guard anchors.count >= 2 else { return }
        elevationAnchors = anchors.sorted { $0.0 < $1.0 }
    }

    /// Sample points for weather fetches: every ~40 mi with local bearing.
    public func weatherSamplePoints(everyMi: Double = 40) -> [WeatherClient.SamplePoint] {
        var samples: [WeatherClient.SamplePoint] = []
        var nextMile = 0.0
        for (i, p) in points.enumerated() where p.mile >= nextMile {
            let ahead = points[min(i + 1, points.count - 1)]
            let bearing = Self.bearingDeg(fromLat: p.latitude, fromLon: p.longitude,
                                          toLat: ahead.latitude, toLon: ahead.longitude)
            samples.append(.init(mile: p.mile, lat: p.latitude, lon: p.longitude,
                                 routeBearingDeg: bearing))
            nextMile = p.mile + everyMi
        }
        return samples
    }

    static func bearingDeg(fromLat: Double, fromLon: Double,
                           toLat: Double, toLon: Double) -> Double {
        let φ1 = fromLat * .pi / 180, φ2 = toLat * .pi / 180
        let Δλ = (toLon - fromLon) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: build

    public static func build(routeCoordinates: [CLLocationCoordinate2D],
                             expectedTravelSeconds: Double,
                             destinationName: String,
                             chargers: [SuperchargerDirectory.Site],
                             maxDetourMi: Double = 6,
                             minSpacingMi: Double = 10) -> RouteCorridor? {
        guard routeCoordinates.count >= 2, expectedTravelSeconds > 0 else { return nil }

        // Downsample the polyline to ~0.5 mi spacing with cumulative miles.
        var points: [RoutePoint] = [RoutePoint(latitude: routeCoordinates[0].latitude,
                                               longitude: routeCoordinates[0].longitude, mile: 0)]
        var mile = 0.0, sinceKept = 0.0
        var lastLat = routeCoordinates[0].latitude, lastLon = routeCoordinates[0].longitude
        for c in routeCoordinates.dropFirst() {
            let d = fastDistanceMi(lastLat, lastLon, c.latitude, c.longitude)
            mile += d; sinceKept += d
            lastLat = c.latitude; lastLon = c.longitude
            if sinceKept >= 0.5 {
                points.append(RoutePoint(latitude: c.latitude, longitude: c.longitude, mile: mile))
                sinceKept = 0
            }
        }
        if let last = points.last, last.mile < mile {
            points.append(RoutePoint(latitude: lastLat, longitude: lastLon, mile: mile))
        }
        let destinationMile = mile
        guard destinationMile > 5 else { return nil }
        let avgSpeedMps = destinationMile * 1609.34 / expectedTravelSeconds

        // Project chargers inside the route's bounding box onto the polyline.
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let margin = 0.15
        let latRange = (lats.min()! - margin)...(lats.max()! + margin)
        let lonRange = (lons.min()! - margin)...(lons.max()! + margin)

        struct Candidate {
            var site: SuperchargerDirectory.Site
            var mile: Double
            var offRouteMi: Double
            var score: Double {
                Double(site.powerKilowatt) * 10 + Double(site.stallCount) - offRouteMi * 20
            }
        }
        var candidates: [Candidate] = []
        for sc in chargers where latRange.contains(sc.latitude) && lonRange.contains(sc.longitude) {
            var bestD = Double.infinity, bestMile = 0.0
            for p in points {
                let d = fastDistanceMi(sc.latitude, sc.longitude, p.latitude, p.longitude)
                if d < bestD { bestD = d; bestMile = p.mile }
            }
            if bestD <= maxDetourMi, bestMile > 2, bestMile < destinationMile - 2 {
                candidates.append(Candidate(site: sc, mile: bestMile, offRouteMi: bestD))
            }
        }
        candidates.sort { $0.mile < $1.mile }

        // Cluster dense metro areas: one best site per minSpacing window so
        // the DP's bounded fan-out spans real distance, not one city block.
        var kept: [Candidate] = []
        for c in candidates {
            if let last = kept.last, c.mile - last.mile < minSpacingMi {
                if c.score > last.score { kept[kept.count - 1] = c }
            } else {
                kept.append(c)
            }
        }

        let sites = kept.map { c in
            Supercharger(
                id: "sc\(c.site.id)", name: c.site.name,
                coordinate: CLLocationCoordinate2D(latitude: c.site.latitude,
                                                   longitude: c.site.longitude),
                version: version(powerKW: c.site.powerKilowatt),
                stallCount: c.site.stallCount,
                detourSecondsWestbound: detourSeconds(offRouteMi: c.offRouteMi),
                detourSecondsEastbound: detourSeconds(offRouteMi: c.offRouteMi),
                occupancy: .unknown,
                healthScore: 1.0,
                routeMile: c.mile)
        }

        var anchors = kept.map { ($0.mile, $0.site.elevationMeters) }
        if anchors.isEmpty { anchors = [(0, 200), (destinationMile, 200)] }

        return RouteCorridor(destinationName: destinationName,
                             destinationMile: destinationMile,
                             sites: sites, points: points,
                             avgSpeedMps: avgSpeedMps,
                             elevationAnchors: anchors)
    }

    // MARK: queries

    public func mile(of coord: CLLocationCoordinate2D) -> Double {
        nearestPoint(to: coord).mile
    }

    public func distanceToRouteMi(_ coord: CLLocationCoordinate2D) -> Double {
        let p = nearestPoint(to: coord)
        return Self.fastDistanceMi(coord.latitude, coord.longitude, p.latitude, p.longitude)
    }

    private func nearestPoint(to coord: CLLocationCoordinate2D) -> RoutePoint {
        var best = points[0], bestD = Double.infinity
        for p in points {
            let d = Self.fastDistanceMi(coord.latitude, coord.longitude, p.latitude, p.longitude)
            if d < bestD { bestD = d; best = p }
        }
        return best
    }

    /// Leg builder for the DP planner: elevation from the terrain anchors,
    /// wind/temp/rain interpolated from the live forecast at the leg
    /// midpoint. Rain slows the leg (~3%/mm·h, capped 15%) on top of the
    /// energy model's wet-road penalty.
    public func legBuilder(ambientTempC defaultAmbientC: Double) -> TripPlanner.LegBuilder {
        let elevAnchors = elevationAnchors
        let weather = weatherAnchors
        let baseSpeed = max(10, avgSpeedMps)
        return { from, to in
            let miles = max(0.1, to - from)
            let n = max(2, min(64, Int(miles / 5) + 2))
            let elevations = (0..<n).map { i in
                Float(ChargeCurveModel.interpolate(
                    elevAnchors, at: from + miles * Double(i) / Double(n - 1)))
            }
            let mid = (from + to) / 2
            var wind = WindForecast(headwindMps: 0, crosswindMps: 0)
            var ambient = defaultAmbientC
            var precip = 0.0
            if !weather.isEmpty {
                func at(_ keyPath: KeyPath<WeatherAnchor, Double>) -> Double {
                    ChargeCurveModel.interpolate(weather.map { ($0.mile, $0[keyPath: keyPath]) }, at: mid)
                }
                wind = WindForecast(headwindMps: at(\.headwindMps),
                                    crosswindMps: at(\.crosswindMps),
                                    sigmaMps: at(\.sigmaMps))
                ambient = at(\.ambientC)
                precip = max(0, at(\.precipMmPerHour))
            }
            let speed = baseSpeed * (1 - min(0.15, precip * 0.03))
            return RouteLeg(
                fromSiteID: "", toSiteID: "", distanceMi: miles,
                elevation: ElevationProfile(stepMeters: miles * 1609.34 / Double(n - 1),
                                            elevationsM: elevations),
                wind: wind,
                ambientTempC: ambient,
                precipMmPerHour: precip,
                trafficDriveSeconds: miles * 1609.34 / speed,
                avgSpeedMps: speed)
        }
    }

    // MARK: helpers

    static func version(powerKW: Int) -> SuperchargerVersion {
        switch powerKW {
        case ..<100: .v2urban
        case ..<200: .v2
        case ..<300: .v3
        default: .v4stall
        }
    }

    static func detourSeconds(offRouteMi: Double) -> Double {
        180 + offRouteMi * 2 / 28 * 3600   // exit + local roads both ways
    }

    /// Equirectangular approximation — plenty accurate for projection and
    /// ~100x cheaper than CLLocation haversine over millions of pairs.
    static func fastDistanceMi(_ lat1: Double, _ lon1: Double,
                               _ lat2: Double, _ lon2: Double) -> Double {
        let ky = 69.0
        let kx = cos(lat1 * .pi / 180) * 69.17
        let dy = (lat1 - lat2) * ky, dx = (lon1 - lon2) * kx
        return (dx * dx + dy * dy).squareRoot()
    }
}
