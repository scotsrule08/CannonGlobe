import Foundation

/// Open-Meteo forecast client (free, keyless — docs §4.5). Fetches hourly
/// wind + temp at sparse points along the corridor and decomposes wind into
/// head/cross components against the local route bearing.
public struct WeatherClient: Sendable {
    public struct PointForecast: Sendable {
        public var mile: Double
        public var headwindMps: Double
        public var crosswindMps: Double
        public var sigmaMps: Double
        public var ambientC: Double
    }

    public struct SamplePoint: Sendable {
        public var mile: Double
        public var lat: Double
        public var lon: Double
        public var routeBearingDeg: Double   // direction of travel at this point
        public init(mile: Double, lat: Double, lon: Double, routeBearingDeg: Double) {
            self.mile = mile; self.lat = lat; self.lon = lon
            self.routeBearingDeg = routeBearingDeg
        }
    }

    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// One batched call per ~25-mi sample point set (Open-Meteo accepts
    /// comma-separated coordinate lists). `hoursAhead` picks the forecast hour
    /// matching predicted arrival at each point.
    public func forecast(points: [SamplePoint], hoursAhead: [Int]) async throws -> [PointForecast] {
        guard !points.isEmpty else { return [] }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: points.map { String(format: "%.3f", $0.lat) }.joined(separator: ",")),
            .init(name: "longitude", value: points.map { String(format: "%.3f", $0.lon) }.joined(separator: ",")),
            .init(name: "hourly", value: "temperature_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
            .init(name: "wind_speed_unit", value: "ms"),
            .init(name: "forecast_days", value: "2"),
        ]
        let (data, response) = try await session.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // Open-Meteo returns an array for multi-location, an object for single.
        let locations: [OpenMeteoDTO]
        if let many = try? JSONDecoder().decode([OpenMeteoDTO].self, from: data) {
            locations = many
        } else {
            locations = [try JSONDecoder().decode(OpenMeteoDTO.self, from: data)]
        }
        return zip(points.indices, locations).map { i, dto in
            let hour = min(max(0, hoursAhead[min(i, hoursAhead.count - 1)]),
                           dto.hourly.windSpeed10m.count - 1)
            let speed = dto.hourly.windSpeed10m[hour]
            let fromDeg = dto.hourly.windDirection10m[hour]
            let gust = dto.hourly.windGusts10m[hour]
            // Wind blows FROM fromDeg; component along travel bearing:
            let rel = (fromDeg - points[i].routeBearingDeg) * .pi / 180
            let head = speed * cos(rel)          // + = headwind
            let cross = abs(speed * sin(rel))
            // Forecast σ: base 1.2 m/s plus gustiness spread.
            let sigma = 1.2 + max(0, gust - speed) * 0.35
            return PointForecast(mile: points[i].mile, headwindMps: head,
                                 crosswindMps: cross, sigmaMps: sigma,
                                 ambientC: dto.hourly.temperature2m[hour])
        }
    }
}

struct OpenMeteoDTO: Decodable {
    struct Hourly: Decodable {
        var temperature2m: [Double]
        var windSpeed10m: [Double]
        var windDirection10m: [Double]
        var windGusts10m: [Double]
        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case windSpeed10m = "wind_speed_10m"
            case windDirection10m = "wind_direction_10m"
            case windGusts10m = "wind_gusts_10m"
        }
    }
    var hourly: Hourly
}
