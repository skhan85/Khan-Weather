import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A real measurement from a weather station, as opposed to a model estimate.
public struct Observation: Equatable, Codable, Sendable {
    public var stationName: String
    public var observedAt: Date
    public var temperature: Double
    /// Wind chill or humidex when Environment Canada reports one.
    public var feelsLike: Double?
    public var feelsLikeKind: FeelsLikeKind?
    public var humidity: Double?
    public var windSpeed: Double?
    public var windDirection: Double?
    /// Nil when the station reported no sky condition, or one we don't recognise.
    public var condition: WeatherCondition?
    public var conditionText: String?
    /// How far the station is from the user, when known.
    public var distanceKm: Double?
    /// Who runs the station when it isn't ECCC itself, e.g. "ON-MTO" or "NAV CANADA".
    public var dataProvider: String?
    /// When the sky (condition) came from a different station than the readings.
    public var skyStationName: String?

    public init(stationName: String, observedAt: Date, temperature: Double, feelsLike: Double? = nil,
                feelsLikeKind: FeelsLikeKind? = nil, humidity: Double? = nil, windSpeed: Double? = nil,
                windDirection: Double? = nil, condition: WeatherCondition? = nil, conditionText: String? = nil,
                distanceKm: Double? = nil) {
        self.stationName = stationName
        self.observedAt = observedAt
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.feelsLikeKind = feelsLikeKind
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.condition = condition
        self.conditionText = conditionText
        self.distanceKm = distanceKm
    }

    /// Stations closer than this stand in for the user's own spot: temperature, wind and feels-like.
    /// Farther ones only tell us what the sky is doing (rain, snow, fog).
    public static let localRadiusKm: Double = 15

    public var isLocal: Bool { (distanceKm ?? 0) <= Self.localRadiusKm }
}

public protocol ObservationProvider: Sendable {
    var attribution: String { get }
    /// The latest nearby observation, or nil if this provider has none for the location.
    func observation(near coordinate: Coordinate) async throws -> Observation?
}

/// Observed current conditions from Environment and Climate Change Canada's city pages
/// (https://api.weather.gc.ca, collection `citypageweather-realtime`). Free, no key. Canada only.
public struct EnvironmentCanadaProvider: ObservationProvider {
    public typealias DataLoader = OpenMeteoProvider.DataLoader

    public let attribution = "Observations: Environment and Climate Change Canada"

    /// Ignore stations farther than this from the user; a distant airport misleads more than it helps.
    public var maxStationDistanceKm: Double = 60
    /// Ignore observations older than this.
    public var maxAge: TimeInterval = 3 * 3600

    private let baseURL: URL
    private let loader: DataLoader

    public init(
        baseURL: URL = URL(string: "https://api.weather.gc.ca/collections/citypageweather-realtime/items")!,
        loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.loader = loader
    }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        // Rough bounding box first; Canada's city pages are dense in the south, sparse in the north.
        guard Self.mightBeInCanada(coordinate) else { return nil }
        for span in [0.6, 2.0] {
            let data = try await fetch(url(for: coordinate, span: span))
            if let observation = try Self.parse(data, near: coordinate, now: Date(),
                                                maxDistanceKm: maxStationDistanceKm, maxAge: maxAge) {
                return observation
            }
        }
        return nil
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await loader(URLRequest(url: url, timeoutInterval: 20))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return data
    }

    func url(for c: Coordinate, span: Double) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let bbox = [c.longitude - span * 1.5, c.latitude - span, c.longitude + span * 1.5, c.latitude + span]
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "limit", value: "30"),
        ]
        return components.url!
    }

    static func mightBeInCanada(_ c: Coordinate) -> Bool {
        (41.5...84).contains(c.latitude) && (-141.5...(-52)).contains(c.longitude)
    }

    // MARK: - Parsing

    /// Picks the city page whose observing station is nearest to `coordinate`.
    static func parse(_ data: Data, near coordinate: Coordinate, now: Date,
                      maxDistanceKm: Double, maxAge: TimeInterval) throws -> Observation? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else {
            throw ForecastError.missingData("features")
        }

        var candidates: [Observation] = []
        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let current = properties["currentConditions"] as? [String: Any],
                  var observation = observation(from: current) else { continue }
            guard now.timeIntervalSince(observation.observedAt) <= maxAge else { continue }

            // Prefer the station's own position; fall back to the city point.
            let station = current["station"] as? [String: Any]
            let stationCoordinate = Self.coordinate(lat: en(station?["lat"]), lon: en(station?["lon"]))
                ?? pointCoordinate(feature["geometry"])
            guard let stationCoordinate else { continue }
            let distance = distanceKm(coordinate, stationCoordinate)
            guard distance <= maxDistanceKm else { continue }
            observation.distanceKm = distance
            // Several city pages share one station (Milton and Mississauga both use Pearson).
            if !candidates.contains(where: { $0.stationName == observation.stationName }) {
                candidates.append(observation)
            }
        }
        return choose(from: candidates)
    }

    /// Automatic stations such as Burlington Lift Bridge report temperature and wind but no sky.
    /// Take the sky from the nearest station that does report one.
    static func choose(from candidates: [Observation]) -> Observation? {
        let sorted = candidates.sorted { ($0.distanceKm ?? 0) < ($1.distanceKm ?? 0) }
        guard let nearest = sorted.first else { return nil }
        if nearest.conditionText != nil { return nearest }
        guard let withSky = sorted.first(where: { $0.conditionText != nil }) else { return nearest }
        // A distant station only supplies the sky anyway, so use the one that has it.
        guard nearest.isLocal else { return withSky }
        var merged = nearest
        merged.condition = withSky.condition
        merged.conditionText = withSky.conditionText
        return merged
    }

    static func observation(from current: [String: Any]) -> Observation? {
        guard let temperature = number(current["temperature"]) else { return nil }
        guard let timestamp = en(current["timestamp"]) as? String,
              let observedAt = parseDate(timestamp) else { return nil }

        let station = current["station"] as? [String: Any]
        let stationName = (en(station?["value"]) as? String) ?? (en(station) as? String) ?? "Nearby station"

        let wind = current["wind"] as? [String: Any]
        let windSpeed = number(wind?["speed"])

        // Work feels-like out from the measurements ourselves. The city page's own windChill value
        // has been seen well below what its temperature and wind give (−6 for 6° and 39 km/h).
        var feelsLike: Double?
        var kind: FeelsLikeKind?
        if let chill = windChill(temperature: temperature, windKmh: windSpeed) {
            feelsLike = chill; kind = .windChill
        } else if let hx = humidex(temperature: temperature, dewpoint: number(current["dewpoint"])) {
            feelsLike = hx; kind = .humidex
        }

        let text = (en(current["condition"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return Observation(
            stationName: stationName,
            observedAt: observedAt,
            temperature: temperature,
            feelsLike: feelsLike,
            feelsLikeKind: kind,
            humidity: number(current["relativeHumidity"]),
            windSpeed: windSpeed,
            windDirection: number(wind?["bearing"]),
            condition: text.flatMap(condition(fromText:)),
            conditionText: (text?.isEmpty ?? true) ? nil : text
        )
    }

    /// Environment Canada's wind chill index. Defined only at or below 10 °C with wind of at least 5 km/h.
    static func windChill(temperature t: Double, windKmh v: Double?) -> Double? {
        guard let v, t <= 10, v >= 5 else { return nil }
        let p = pow(v, 0.16)
        let chill = 13.12 + 0.6215 * t - 11.37 * p + 0.3965 * t * p
        return min(chill, t)
    }

    /// Environment Canada's humidex from dew point. Reported only when it's warm and muggy enough to matter.
    static func humidex(temperature t: Double, dewpoint td: Double?) -> Double? {
        guard let td, t >= 20 else { return nil }
        let e = 6.11 * exp(5417.7530 * (1 / 273.16 - 1 / (273.15 + td)))
        let h = t + 0.5555 * (e - 10)
        return h - t >= 1 ? h : nil
    }

    /// Maps Environment Canada's English condition text ("Light Rain", "Mostly Cloudy") to our enum.
    static func condition(fromText raw: String) -> WeatherCondition? {
        let text = raw.lowercased()
        if text.isEmpty || text.contains("not observed") { return nil }
        if text.contains("thunder") { return text.contains("hail") ? .thunderstormHail : .thunderstorm }
        if text.contains("hail") || text.contains("ice pellet") { return .thunderstormHail }
        if text.contains("freezing drizzle") { return .freezingDrizzle }
        if text.contains("freezing rain") { return .freezingRain }
        if text.contains("drizzle") { return .drizzle }
        if text.contains("snow grains") || text.contains("ice crystals") { return .snowGrains }
        if text.contains("flurr") || text.contains("snow shower") || text.contains("snowshower") { return .snowShowers }
        if text.contains("snow") { return .snow }
        if text.contains("rain shower") || text.contains("rainshower") || text.contains("shower") { return .rainShowers }
        if text.contains("rain") || text.contains("precipitation") { return .rain }
        if text.contains("fog") || text.contains("mist") || text.contains("haze") || text.contains("smoke") { return .fog }
        if text.contains("mainly sunny") || text.contains("mainly clear") { return .mainlyClear }
        if text.contains("sunny") || text.contains("clear") { return .clear }
        if text.contains("partly") || text.contains("mostly cloudy") || text.contains("a few clouds") { return .partlyCloudy }
        if text.contains("cloud") || text.contains("overcast") { return .overcast }
        return nil
    }

    // MARK: - Bilingual JSON helpers. Every leaf looks like {"en": …, "fr": …}.

    static func en(_ value: Any?) -> Any? {
        if let dict = value as? [String: Any] { return dict["en"] ?? dict.values.first }
        return value
    }

    /// Reads {"value": {"en": 4.0}} or {"en": 4.0}, as a number or numeric string.
    static func number(_ value: Any?) -> Double? {
        var leaf: Any? = value
        if let dict = value as? [String: Any], let inner = dict["value"] { leaf = inner }
        leaf = en(leaf)
        if let n = leaf as? NSNumber { return n.doubleValue }
        if let s = leaf as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// "43.68N" / "79.63W" → signed degrees.
    static func coordinate(lat: Any?, lon: Any?) -> Coordinate? {
        func degrees(_ any: Any?, negative: Character) -> Double? {
            guard var s = (any as? String)?.trimmingCharacters(in: .whitespaces).uppercased(), !s.isEmpty else { return nil }
            var sign = 1.0
            if let last = s.last, last.isLetter {
                if last == negative || (negative == "W" && last == "O") { sign = -1 }
                s.removeLast()
            }
            return Double(s).map { $0 * sign }
        }
        guard let la = degrees(lat, negative: "S"), let lo = degrees(lon, negative: "W") else { return nil }
        return Coordinate(latitude: la, longitude: lo)
    }

    static func pointCoordinate(_ geometry: Any?) -> Coordinate? {
        guard let g = geometry as? [String: Any], let c = g["coordinates"] as? [Any], c.count >= 2,
              let lon = (c[0] as? NSNumber)?.doubleValue, let lat = (c[1] as? NSNumber)?.doubleValue else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    static func distanceKm(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

public extension Forecast {
    /// Replaces the model's "now" with a station observation where the station has data.
    /// Hourly and daily forecasts are left alone.
    func applying(_ observation: Observation?) -> Forecast {
        guard let o = observation else { return self }
        var copy = self
        var c = current
        copy.observation = o
        guard o.isLocal else {
            // A distant station (a lakeshore pier, an airport across town) can't speak for the
            // user's temperature or wind, but it does tell us whether it's raining.
            c.condition = o.condition ?? c.condition
            copy.current = c
            return copy
        }
        c.temperature = o.temperature
        // Wind chill from the stronger of the station's wind and the forecast wind for this spot.
        // A single sheltered sensor can read near-calm while the town is breezy; in winter it's
        // safer to err cold.
        let chillWind = max(o.windSpeed ?? 0, current.windSpeed ?? 0)
        if let chill = EnvironmentCanadaProvider.windChill(temperature: o.temperature, windKmh: chillWind) {
            c.feelsLike = chill
            c.feelsLikeKind = .windChill
        } else if let feels = o.feelsLike, let kind = o.feelsLikeKind, kind != .windChill {
            c.feelsLike = feels
            c.feelsLikeKind = kind
        } else {
            // No wind chill or humidex reported: it feels like the actual temperature.
            c.feelsLike = o.temperature
        }
        c.humidity = o.humidity ?? c.humidity
        c.windSpeed = o.windSpeed ?? c.windSpeed
        c.windDirection = o.windDirection ?? c.windDirection
        c.condition = o.condition ?? c.condition
        c.time = o.observedAt
        copy.current = c
        return copy
    }
}
