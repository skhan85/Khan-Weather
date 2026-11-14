import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Air quality and pollen at one spot, from Open-Meteo's free air-quality API (CAMS data).
public struct AirQuality: Equatable, Codable, Sendable {
    public var time: Date
    /// US EPA Air Quality Index, 0–500.
    public var usAQI: Double?
    /// Highest US AQI in the rest of today, for "up to 65 later".
    public var todayMaxAQI: Double?
    /// µg/m³
    public var pm25: Double?
    public var pm10: Double?
    public var ozone: Double?
    public var nitrogenDioxide: Double?
    /// Pollen with a count above zero. Open-Meteo only has pollen for Europe, so it's empty elsewhere.
    public var pollen: [Pollen]
    /// True when the model covers pollen here at all (Europe), even if every count is zero today.
    public var hasPollenData: Bool

    public init(time: Date, usAQI: Double? = nil, todayMaxAQI: Double? = nil, pm25: Double? = nil, pm10: Double? = nil,
                ozone: Double? = nil, nitrogenDioxide: Double? = nil, pollen: [Pollen] = [], hasPollenData: Bool = false) {
        self.time = time
        self.usAQI = usAQI
        self.todayMaxAQI = todayMaxAQI
        self.pm25 = pm25
        self.pm10 = pm10
        self.ozone = ozone
        self.nitrogenDioxide = nitrogenDioxide
        self.pollen = pollen
        self.hasPollenData = hasPollenData
    }

    public var category: AQICategory? { usAQI.map(AQICategory.init(aqi:)) }
}

/// The EPA's six bands.
public enum AQICategory: Int, Codable, Sendable, Comparable {
    case good, moderate, sensitive, unhealthy, veryUnhealthy, hazardous

    public init(aqi: Double) {
        switch aqi {
        case ..<50.5: self = .good
        case ..<100.5: self = .moderate
        case ..<150.5: self = .sensitive
        case ..<200.5: self = .unhealthy
        case ..<300.5: self = .veryUnhealthy
        default: self = .hazardous
        }
    }

    public var label: String {
        switch self {
        case .good: return "Good"
        case .moderate: return "Moderate"
        case .sensitive: return "Unhealthy for sensitive groups"
        case .unhealthy: return "Unhealthy"
        case .veryUnhealthy: return "Very unhealthy"
        case .hazardous: return "Hazardous"
        }
    }

    /// One line of advice.
    public var advice: String {
        switch self {
        case .good: return "Air is clean. A good time to be outside."
        case .moderate: return "Fine for most people. If you're very sensitive, take it easier outdoors."
        case .sensitive: return "People with asthma, heart or lung conditions, kids and older adults should cut back on long outdoor exertion."
        case .unhealthy: return "Everyone should cut back on long or heavy outdoor exertion."
        case .veryUnhealthy: return "Avoid long or heavy outdoor exertion. Sensitive people should stay indoors."
        case .hazardous: return "Stay indoors and keep windows closed."
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct Pollen: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case alder, birch, grass, mugwort, olive, ragweed

        public var label: String { rawValue.capitalized }

        enum Group { case tree, grass, weed }
        var group: Group {
            switch self {
            case .alder, .birch, .olive: return .tree
            case .grass: return .grass
            case .mugwort, .ragweed: return .weed
            }
        }
    }

    public enum Level: Int, Codable, Sendable, Comparable {
        case low, moderate, high, veryHigh
        public var label: String {
            switch self {
            case .low: return "Low"
            case .moderate: return "Moderate"
            case .high: return "High"
            case .veryHigh: return "Very high"
            }
        }
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    /// Grains per m³.
    public var grains: Double
    public var id: Kind { kind }

    public init(kind: Kind, grains: Double) {
        self.kind = kind
        self.grains = grains
    }

    /// US National Allergy Bureau bands, which differ for trees, grass and weeds.
    public var level: Level {
        let (moderate, high, veryHigh): (Double, Double, Double)
        switch kind.group {
        case .tree: (moderate, high, veryHigh) = (15, 90, 1500)
        case .grass: (moderate, high, veryHigh) = (5, 20, 200)
        case .weed: (moderate, high, veryHigh) = (10, 50, 500)
        }
        if grains >= veryHigh { return .veryHigh }
        if grains >= high { return .high }
        if grains >= moderate { return .moderate }
        return .low
    }
}

public struct AirQualityProvider: Sendable {
    let loader: HTTPLoader
    let baseURL: URL

    public init(baseURL: URL = URL(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!,
                loader: @escaping HTTPLoader = defaultLoader) {
        self.baseURL = baseURL
        self.loader = loader
    }

    static let pollutants = ["us_aqi", "pm2_5", "pm10", "ozone", "nitrogen_dioxide"]
    static var pollenFields: [String] { Pollen.Kind.allCases.map { "\($0.rawValue)_pollen" } }

    func url(for coordinate: Coordinate) -> URL {
        let c = coordinate.rounded
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(c.latitude)),
            URLQueryItem(name: "longitude", value: String(c.longitude)),
            URLQueryItem(name: "current", value: (Self.pollutants + Self.pollenFields).joined(separator: ",")),
            URLQueryItem(name: "hourly", value: "us_aqi"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        return components.url!
    }

    public func airQuality(at coordinate: Coordinate) async throws -> AirQuality {
        let data = try await fetch(url(for: coordinate), loader: loader)
        return try Self.parse(data)
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let us_aqi: [Double?]?
        }
        let current: [String: FlexibleNumber]
        let hourly: Hourly?
    }

    /// Open-Meteo's "current" block mixes numbers, nulls and the odd string.
    private enum FlexibleNumber: Decodable {
        case number(Double), other
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .other }
        }
        var value: Double? { if case .number(let d) = self { return d }; return nil }
    }

    static func parse(_ data: Data) throws -> AirQuality {
        let r = try JSONDecoder().decode(Response.self, from: data)
        func value(_ key: String) -> Double? { r.current[key]?.value }
        let time = Date(timeIntervalSince1970: value("time") ?? Date().timeIntervalSince1970)
        var pollen: [Pollen] = []
        var hasPollen = false
        for kind in Pollen.Kind.allCases {
            guard let grains = value("\(kind.rawValue)_pollen") else { continue }
            hasPollen = true
            if grains >= 1 { pollen.append(Pollen(kind: kind, grains: grains)) }
        }
        pollen.sort { $0.grains > $1.grains }
        var todayMax: Double?
        if let h = r.hourly, let aqi = h.us_aqi {
            // From the current hour on; the request covers just today.
            let later = zip(h.time, aqi).filter { $0.0 + 3600 > time.timeIntervalSince1970 }.compactMap(\.1)
            todayMax = later.max()
        }
        return AirQuality(time: time, usAQI: value("us_aqi"), todayMaxAQI: todayMax,
                          pm25: value("pm2_5"), pm10: value("pm10"), ozone: value("ozone"),
                          nitrogenDioxide: value("nitrogen_dioxide"), pollen: pollen, hasPollenData: hasPollen)
    }
}
