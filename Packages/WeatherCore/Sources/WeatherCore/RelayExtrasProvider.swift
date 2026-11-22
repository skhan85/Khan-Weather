import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RelayHazards: Codable, Equatable, Sendable {
    public struct Lightning: Codable, Equatable, Sendable {
        public let count: Int
        public let distance_km: Double?
        public let bearing: String?
        public let observed: Double?
    }
    public struct Hail: Codable, Equatable, Sendable {
        public let distance_km: Double?
        public let bearing: String?
        public let max_size_mm: Double?
        public let severe: Bool?
    }
    public struct Road: Codable, Equatable, Sendable {
        public let surface: String?
        public let temp_c: Double?
        public let ice_mm: Double?
        public let snow_mm: Double?
        public let water_mm: Double?
    }

    public let generated: Double?
    public let lightning: Lightning?
    public let hail: Hail?
    public let road: Road?

    public struct Banner: Equatable, Sendable, Identifiable {
        public let id: String
        public let icon: String
        public let text: String
    }

    public var banners: [Banner] {
        var out: [Banner] = []
        if let l = lightning, l.count > 0 {
            let dist = l.distance_km.map { "\(Int($0.rounded())) km" } ?? "nearby"
            let dir = l.bearing.map { " \($0)" } ?? ""
            out.append(Banner(id: "lightning", icon: "bolt.fill",
                              text: "Lightning \(dist)\(dir) (\(l.count) recent strike\(l.count == 1 ? "" : "s"))."))
        }
        if let h = hail {
            let dist = h.distance_km.map { "\(Int($0.rounded())) km" } ?? "nearby"
            let dir = h.bearing.map { " \($0)" } ?? ""
            let size = (h.max_size_mm ?? 0) > 0 ? " (up to \(Int(h.max_size_mm!.rounded())) mm)" : ""
            out.append(Banner(id: "hail", icon: "cloud.hail.fill",
                              text: "Hail threat \(dist)\(dir)\(size)."))
        }
        if let r = road {
            let ice = r.ice_mm ?? 0
            let snow = r.snow_mm ?? 0
            let surf = (r.surface ?? "").lowercased()
            let wintry = ice >= 0.1 || snow >= 1.0 || surf.contains("ice") || surf.contains("snow") || surf.contains("slush") || surf.contains("freez")
            if wintry {
                let label = r.surface?.capitalized ?? "Wintry roads"
                let detail = ice >= 0.1 ? String(format: " (%.1f mm ice)", ice)
                    : (snow >= 1.0 ? String(format: " (%.0f mm snow)", snow) : "")
                out.append(Banner(id: "road", icon: "car.fill", text: "Roads: \(label)\(detail)."))
            }
        }
        return out
    }
}

public struct RelayConsensus: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable, Identifiable {
        public let provider: String
        public let temperature: Double
        public let feels_like: Double?
        public let humidity: Double?
        public let wind_kmh: Double?
        public let high: Double?
        public let low: Double?
        public let condition: String?
        public var id: String { provider }
    }
    public let generated: Double?
    public let sources: [Source]
    public let mean_temperature: Double?
}

public struct RelayExtrasProvider: Sendable {
    public static let defaultHost = URL(string: "https://weather-relay.khanofmilton.ca")!
    private let host: URL

    public init(host: URL = defaultHost) {
        self.host = host
    }

    public func hazards(near c: Coordinate, storms: Bool, cold: Bool) async -> RelayHazards? {
        guard storms || cold else { return nil }
        var parts = URLComponents(url: host.appendingPathComponent("v1/hazards"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
            URLQueryItem(name: "storms", value: storms ? "1" : "0"),
            URLQueryItem(name: "cold", value: cold ? "1" : "0"),
        ]
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RelayHazards.self, from: data)
    }

    public func consensus(near c: Coordinate) async -> RelayConsensus? {
        var parts = URLComponents(url: host.appendingPathComponent("v1/consensus"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
        ]
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RelayConsensus.self, from: data)
    }

    public func stations(near c: Coordinate) async -> [NetatmoStation] {
        var parts = URLComponents(url: host.appendingPathComponent("v1/netatmo"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
        ]
        struct R: Decodable { let stations: [NetatmoStation] }
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(R.self, from: data) else { return [] }
        return decoded.stations
    }
}
