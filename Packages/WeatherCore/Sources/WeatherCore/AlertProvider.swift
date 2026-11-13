import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A public weather alert (warning, watch, advisory or statement) that covers the user's spot.
public struct WeatherAlert: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, Comparable {
        case warning, watch, advisory, statement, other

        /// Warnings first.
        var rank: Int {
            switch self {
            case .warning: return 0
            case .watch: return 1
            case .advisory: return 2
            case .statement: return 3
            case .other: return 4
            }
        }

        public static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }

    public enum Risk: String, Codable, Sendable {
        case red, orange, yellow, unknown
    }

    public var id: String
    /// "Wind warning", sentence case.
    public var title: String
    public var kind: Kind
    public var risk: Risk
    /// Full text, paragraphs separated by blank lines.
    public var text: String
    /// Forecast region it was issued for, e.g. "Halton Hills - Milton".
    public var area: String?
    public var issuedAt: Date?
    public var expiresAt: Date?
    /// When the weather itself is expected to end, if given.
    public var eventEndsAt: Date?
    public var source: String

    public init(id: String, title: String, kind: Kind, risk: Risk, text: String, area: String? = nil,
                issuedAt: Date? = nil, expiresAt: Date? = nil, eventEndsAt: Date? = nil,
                source: String = "Environment and Climate Change Canada") {
        self.id = id
        self.title = title
        self.kind = kind
        self.risk = risk
        self.text = text
        self.area = area
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.eventEndsAt = eventEndsAt
        self.source = source
    }
}

public protocol AlertProvider: Sendable {
    func alerts(near coordinate: Coordinate) async throws -> [WeatherAlert]
}

/// Environment Canada public alerts from the MSC GeoMet OGC API (Open Government Licence – Canada).
/// Outside Canada the query simply comes back empty.
public struct ECCCAlertProvider: AlertProvider {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let loader: DataLoader

    public init(loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }) {
        self.loader = loader
    }

    public func alerts(near coordinate: Coordinate) async throws -> [WeatherAlert] {
        let (data, response) = try await loader(URLRequest(url: Self.url(for: coordinate), timeoutInterval: 20))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return try Self.parse(data, at: coordinate, now: Date())
    }

    static func url(for coordinate: Coordinate) -> URL {
        let c = coordinate.rounded
        // A tiny box around the point; the server matches on polygon bounding boxes,
        // so the exact point-in-polygon check happens in `parse`.
        let d = 0.01
        let bbox = [c.longitude - d, c.latitude - d, c.longitude + d, c.latitude + d]
            .map { String(format: "%.4f", $0) }.joined(separator: ",")
        var comps = URLComponents(string: "https://api.weather.gc.ca/collections/weather-alerts/items")!
        comps.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "limit", value: "100"),
        ]
        return comps.url!
    }

    static func parse(_ data: Data, at point: Coordinate, now: Date) throws -> [WeatherAlert] {
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
        var byID: [String: WeatherAlert] = [:]
        for feature in collection.features {
            let p = feature.properties
            if p.status_en?.lowercased() == "ended" { continue }
            let expires = p.expiration_datetime.flatMap(EnvironmentCanadaProvider.parseDate)
            if let expires, expires <= now { continue }
            guard let geometry = feature.geometry, geometry.contains(point) else { continue }

            // Feature ids look like "<alert id>_<zone id>"; one alert spans many zones.
            let alertID = feature.id.map { String($0.split(separator: "_").first ?? Substring($0)) }
                ?? [p.alert_code, p.publication_datetime].compactMap { $0 }.joined(separator: "-")
            guard byID[alertID] == nil else { continue }
            let name = p.alert_name_en ?? p.alert_short_name_en ?? "Weather alert"
            byID[alertID] = WeatherAlert(
                id: alertID,
                title: name.prefix(1).uppercased() + name.dropFirst(),
                kind: WeatherAlert.Kind(rawValue: p.alert_type?.lowercased() ?? "") ?? .other,
                risk: WeatherAlert.Risk(rawValue: p.risk_colour_en?.lowercased() ?? "") ?? .unknown,
                text: p.alert_text_en ?? "",
                area: p.feature_name_en,
                issuedAt: p.publication_datetime.flatMap(EnvironmentCanadaProvider.parseDate),
                expiresAt: expires,
                eventEndsAt: p.event_end_datetime.flatMap(EnvironmentCanadaProvider.parseDate)
            )
        }
        return byID.values.sorted {
            ($0.kind, $1.issuedAt ?? .distantPast) < ($1.kind, $0.issuedAt ?? .distantPast)
        }
    }

    // MARK: - Wire format

    struct FeatureCollection: Decodable {
        let features: [Feature]
    }

    struct Feature: Decodable {
        let id: String?
        let geometry: Geometry?
        let properties: Properties
    }

    // Property names match the API exactly.
    struct Properties: Decodable {
        let alert_code: String?
        let alert_type: String?
        let alert_name_en: String?
        let alert_short_name_en: String?
        let alert_text_en: String?
        let risk_colour_en: String?
        let status_en: String?
        let feature_name_en: String?
        let publication_datetime: String?
        let expiration_datetime: String?
        let event_end_datetime: String?
    }

    /// GeoJSON Polygon or MultiPolygon with [lon, lat] positions.
    struct Geometry: Decodable {
        /// Polygons, each a list of rings (outer first, then holes).
        let polygons: [[[[Double]]]]

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "Polygon": polygons = [try c.decode([[[Double]]].self, forKey: .coordinates)]
            case "MultiPolygon": polygons = try c.decode([[[[Double]]]].self, forKey: .coordinates)
            default: polygons = []
            }
        }

        func contains(_ point: Coordinate) -> Bool {
            polygons.contains { rings in
                guard let outer = rings.first, Self.ring(outer, contains: point) else { return false }
                return !rings.dropFirst().contains { Self.ring($0, contains: point) }
            }
        }

        /// Ray casting.
        static func ring(_ ring: [[Double]], contains p: Coordinate) -> Bool {
            let pts = ring.filter { $0.count >= 2 }
            guard pts.count >= 3 else { return false }
            var inside = false
            var j = pts.count - 1
            for i in 0..<pts.count {
                let (xi, yi) = (pts[i][0], pts[i][1])
                let (xj, yj) = (pts[j][0], pts[j][1])
                if (yi > p.latitude) != (yj > p.latitude),
                   p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }
}
