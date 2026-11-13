import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A place the user saved, such as work or family, shown alongside the current location.
public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Region and country, e.g. "Ontario, Canada".
    public var detail: String?
    public var coordinate: Coordinate

    public init(id: UUID = UUID(), name: String, detail: String? = nil, coordinate: Coordinate) {
        self.id = id
        self.name = name
        self.detail = detail
        self.coordinate = coordinate
    }
}

/// Place search by name with Open-Meteo's free geocoding API (GeoNames data, CC BY 4.0).
public struct PlaceSearch: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let loader: DataLoader

    public init(loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }) {
        self.loader = loader
    }

    public func search(_ query: String) async throws -> [SavedPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let (data, response) = try await loader(URLRequest(url: Self.url(for: trimmed), timeoutInterval: 15))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return try Self.parse(data)
    }

    static func url(for query: String) -> URL {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return c.url!
    }

    static func parse(_ data: Data) throws -> [SavedPlace] {
        struct Response: Decodable { let results: [Result]? }
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results = try JSONDecoder().decode(Response.self, from: data).results ?? []
        return results.map { r in
            let detail = [r.admin1, r.country].compactMap { $0 }.filter { !$0.isEmpty && $0 != r.name }
            return SavedPlace(name: r.name,
                              detail: detail.isEmpty ? nil : detail.joined(separator: ", "),
                              coordinate: Coordinate(latitude: r.latitude, longitude: r.longitude))
        }
    }
}
