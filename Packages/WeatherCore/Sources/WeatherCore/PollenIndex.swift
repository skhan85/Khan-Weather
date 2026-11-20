import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Today's pollen from Google's Pollen API (Universal Pollen Index, 0–5), served by the family
/// relay so the key never ships in the app. Used where Open-Meteo has no pollen (outside Europe).
public struct PollenIndex: Equatable, Codable, Sendable, Identifiable {
    /// "Tree", "Grass", "Weed", or a plant such as "Birch".
    public var name: String
    /// 0 (none) to 5 (very high).
    public var value: Int
    /// Google's wording: "Very low", "Low", "Moderate", "High", "Very high".
    public var category: String
    public var id: String { name }

    public init(name: String, value: Int, category: String) {
        self.name = name
        self.value = value
        self.category = category
    }
}

public enum PollenIndexProvider {
    /// Same relay as the Netatmo stations.
    public static var url: URL {
        NetatmoRelayProvider.defaultBaseURL.deletingLastPathComponent().appendingPathComponent("pollen")
    }

    /// In-season pollen types with a value above zero, highest first; plants after their types.
    /// Empty out of season. nil if the relay is off or doesn't answer.
    public static func today(at c: Coordinate, loader: HTTPLoader = defaultLoader) async -> [PollenIndex]? {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.2f", c.latitude)),
                            URLQueryItem(name: "lon", value: String(format: "%.2f", c.longitude))]
        var request = URLRequest(url: parts.url!, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await loader(request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? parse(data)
    }

    /// Reads Google's forecast:lookup answer (the relay passes it through unchanged).
    static func parse(_ data: Data) throws -> [PollenIndex] {
        struct Index: Decodable { let value: Int?; let category: String? }
        struct Info: Decodable { let code: String?; let displayName: String?; let inSeason: Bool?; let indexInfo: Index? }
        struct Day: Decodable { let pollenTypeInfo: [Info]?; let plantInfo: [Info]? }
        struct R: Decodable { let dailyInfo: [Day]? }
        guard let day = try JSONDecoder().decode(R.self, from: data).dailyInfo?.first else { return [] }
        func keep(_ list: [Info]?) -> [PollenIndex] {
            (list ?? []).compactMap { i in
                guard i.inSeason == true, let v = i.indexInfo?.value, v > 0, let name = i.displayName else { return nil }
                return PollenIndex(name: name, value: v, category: i.indexInfo?.category ?? "")
            }
            .sorted { $0.value > $1.value }
        }
        let types = keep(day.pollenTypeInfo)
        let typeNames = Set(types.map(\.name))
        // A couple of named plants help ("Birch"), but not ones that just repeat a type's name.
        let plants = keep(day.plantInfo).filter { !typeNames.contains($0.name) }.prefix(3)
        return types + plants
    }
}
