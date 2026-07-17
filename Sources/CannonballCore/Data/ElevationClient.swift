import Foundation

/// Open-Meteo elevation API (free, keyless): batch lat/lon → terrain meters,
/// 100 coordinates per call. Gives dynamic trips a real elevation profile —
/// charger-site interpolation alone misses interior summits like the
/// Eisenhower grade.
public enum ElevationClient {
    public static func elevations(latitudes: [Double], longitudes: [Double],
                                  session: URLSession = .shared) async throws -> [Double] {
        precondition(latitudes.count == longitudes.count)
        var out: [Double] = []
        out.reserveCapacity(latitudes.count)
        for chunkStart in stride(from: 0, to: latitudes.count, by: 100) {
            let end = min(chunkStart + 100, latitudes.count)
            var comps = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
            comps.queryItems = [
                .init(name: "latitude", value: latitudes[chunkStart..<end]
                    .map { String(format: "%.4f", $0) }.joined(separator: ",")),
                .init(name: "longitude", value: longitudes[chunkStart..<end]
                    .map { String(format: "%.4f", $0) }.joined(separator: ",")),
            ]
            let (data, response) = try await session.data(from: comps.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            struct DTO: Decodable { var elevation: [Double] }
            out.append(contentsOf: try JSONDecoder().decode(DTO.self, from: data).elevation)
        }
        return out
    }
}
