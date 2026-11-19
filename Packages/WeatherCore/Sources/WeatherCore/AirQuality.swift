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
/// Environment Canada Air Quality Health Index (1–10+ scale, Canada only).
public var aqhi: Double?
/// Nearest AQHI community name, e.g. "Milton".
public var aqhiStation: String?

    public init(time: Date, usAQI: Double? = nil, todayMaxAQI: Double? = nil, pm25: Double? = nil, pm10: Double? = nil,
                ozone: Double? = nil, nitrogenDioxide: Double? = nil, pollen: [Pollen] = [], hasPollenData: Bool = false, aqhi: Double? = nil, aqhiStation: String? = nil) {
        self.time = time
        self.usAQI = usAQI
        self.todayMaxAQI = todayMaxAQI
        self.pm25 = pm25
        self.pm10 = pm10
        self.ozone = ozone
        self.nitrogenDioxide = nitrogenDioxide
        self.pollen = pollen
        self.hasPollenData = hasPollenData
        self.aqhi = aqhi
        self.aqhiStation = aqhiStation
    }

    public var category: AQICategory? { usAQI.map(AQICategory.init(aqi:)) }

    public var aqhiCategory: AQICategory? {
        guard let aqhi else { return nil }
        switch aqhi {
        case ..<3.5: return .good        // Low Risk (1–3)
        case ..<6.5: return .moderate    // Moderate Risk (4–6)
        case ..<10.5: return .unhealthy  // High Risk (7–10)
        default: return .veryUnhealthy   // Very High Risk (10+)
        }
    }

    public var aqhiRiskLabel: String? {
        guard let aqhi else { return nil }
        switch aqhi {
        case ..<3.5: return "Low risk"
        case ..<6.5: return "Moderate risk"
        case ..<10.5: return "High risk"
        default: return "Very high risk"
        }
    }
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

    /// Environment Canada AQHI health messages.
        public var advice: String {
        switch self {
        case .good: return "Ideal air quality for outdoor activities. Enjoy your usual outdoor activities."
        case .moderate: return "No need to modify your usual outdoor activities unless you experience symptoms such as coughing and throat irritation."
        case .sensitive: return "Consider reducing or rescheduling strenuous activities outdoors if you are experiencing symptoms."
        case .unhealthy: return "Reduce or reschedule strenuous activities outdoors. Children and the elderly should also take it easy."
        case .veryUnhealthy, .hazardous: return "Avoid strenuous activities outdoors. Children and the elderly should also avoid outdoor physical exertion."    
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
        async let openMeteoData = fetch(url(for: coordinate), loader: loader)
        async let ecccAQHI: (value: Double, station: String)? = Region.inCanada(coordinate)
            ? (try? await fetchAQHI(near: coordinate))
            : nil
        var aq = try Self.parse(try await openMeteoData)
        if let eccc = await ecccAQHI {
            aq.aqhi = eccc.value
            aq.aqhiStation = eccc.station
        }
        return aq
    }

    private func fetchAQHI(near c: Coordinate) async throws -> (value: Double, station: String)? {
        let span = 0.45
        let bbox = [c.longitude - span * 1.4, c.latitude - span,
                    c.longitude + span * 1.4, c.latitude + span]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
        var comps = URLComponents(string: "https://api.weather.gc.ca/collections/aqhi-observations-realtime/items")!
        comps.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "latest", value: "true"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        let data = try await fetch(comps.url!, loader: loader)
        return Self.parseAQHI(data, near: c)
    }

    static func parseAQHI(_ data: Data, near c: Coordinate) -> (value: Double, station: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return nil }
        var best: (dist: Double, value: Double, station: String)?
        for f in features {
            guard let p = f["properties"] as? [String: Any],
                  let val = (p["aqhi"] as? NSNumber)?.doubleValue,
                  let point = EnvironmentCanadaProvider.pointCoordinate(f["geometry"]) else { continue }
            let d = EnvironmentCanadaProvider.distanceKm(c, point)
            guard d < (best?.dist ?? .infinity) else { continue }
            let name = (p["location_name_en"] as? String) ?? "Nearby station"
            best = (d, val, name)
        }
        return best.map { ($0.value, $0.station) }
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
