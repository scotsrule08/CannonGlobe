import Foundation

/// Live Supercharger directory from supercharge.info: every open site with
/// stall count, cabinet power, and elevation. Disk-cached for a week so a
/// trip can be planned offline after the first fetch.
public actor SuperchargerDirectory {
    public struct Site: Sendable, Codable {
        public var id: Int
        public var name: String
        public var latitude: Double
        public var longitude: Double
        public var stallCount: Int
        public var powerKilowatt: Int
        public var elevationMeters: Double
    }

    public static let shared = SuperchargerDirectory()

    private var memo: [Site]?
    private let endpoint = URL(string: "https://supercharge.info/service/supercharge/allSites")!
    private let maxCacheAge: TimeInterval = 7 * 86400
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("supercharger-directory.json")
    }

    public func sites() async throws -> [Site] {
        if let memo { return memo }
        if let cached = loadCache(maxAge: maxCacheAge) {
            memo = cached
            return cached
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let open = try JSONDecoder().decode([SiteDTO].self, from: data)
                .filter { $0.status == "OPEN" }
                .map(\.site)
            memo = open
            try? JSONEncoder().encode(open).write(to: cacheURL)
            return open
        } catch {
            // Offline: any cache, however stale, beats no directory.
            if let stale = loadCache(maxAge: .infinity) {
                memo = stale
                return stale
            }
            throw error
        }
    }

    private func loadCache(maxAge: TimeInterval) -> [Site]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: cacheURL),
              let sites = try? JSONDecoder().decode([Site].self, from: data)
        else { return nil }
        return sites
    }

    private struct SiteDTO: Decodable {
        struct GPS: Decodable { var latitude: Double; var longitude: Double }
        var id: Int
        var name: String
        var status: String
        var gps: GPS
        var stallCount: Int?
        var powerKilowatt: Int?
        var elevationMeters: Double?

        var site: Site {
            Site(id: id, name: name,
                 latitude: gps.latitude, longitude: gps.longitude,
                 stallCount: stallCount ?? 8,
                 powerKilowatt: powerKilowatt ?? 150,
                 elevationMeters: elevationMeters ?? 0)
        }
    }
}
