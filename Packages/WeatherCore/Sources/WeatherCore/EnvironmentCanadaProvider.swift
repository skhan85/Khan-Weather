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
    public var windGusts: Double?
    /// Nil when the station reported no sky condition, or one we don't recognise.
    public var condition: WeatherCondition?
    public var conditionText: String?
    /// How far the station is from the user, when known.
    public var distanceKm: Double?
    /// Who runs the station when it isn't ECCC itself, e.g. "ON-MTO" or "NAV CANADA".
    public var dataProvider: String?
    /// When the sky (condition) came from a different station than the readings.
    public var skyStationName: String?
    /// Who runs the sky station, when it differs from the readings (e.g. Netatmo readings, ECCC sky).
    /// nil with a skyStationName means Environment Canada.
    public var skyDataProvider: String?
    /// Nearby home rain gauges (Netatmo) that reported, and the most any of them caught in the
    /// last hour, in mm. Several dry gauges next door outrank a distant station or a faint radar echo.
    /// How far the sky station is, when the sky came from a different station than the readings.
    public var skyDistanceKm: Double?
    /// Whether the sky (rain, snow, cloud) was reported within `localRadiusKm`.
    public var skyIsLocal: Bool {
        skyStationName == nil ? isLocal : (skyDistanceKm ?? .infinity) <= Self.localRadiusKm
    }
    public var rainGauges: Int?
    public var rainLastHourMm: Double?
    /// Home stations only: each nearby station's reading, nearest first, so a sun-heated one can
    /// be set aside against the forecast (see `Forecast.applying(_:)`).
    public var stationTemperatures: [Double]?
    /// Home stations only: the official station they were allowed to disagree with by more than
    /// `HyperlocalObservationProvider.tieBreakGap`, kept so the models can break the tie
    /// (see `Forecast.applying(_:)`).
    public var officialTemperature: Double?
    public var officialStationName: String?
    public var officialDistanceKm: Double?
    public var officialProvider: String?
    /// Where the station is, when the service says.
    public var stationCoordinate: Coordinate?
    /// The model blend's temperature at the station's own spot at `observedAt`, fetched only for a
    /// station beyond `localRadiusKm` (see `neighbourShift`).
    public var modelAtStation: Double?

    /// Local gauges report and none caught a drop in the last hour.
    public var gaugesSayDry: Bool { (rainGauges ?? 0) > 0 && (rainLastHourMm ?? 1) == 0 }

    public init(stationName: String, observedAt: Date, temperature: Double, feelsLike: Double? = nil,
                feelsLikeKind: FeelsLikeKind? = nil, humidity: Double? = nil, windSpeed: Double? = nil,
                windDirection: Double? = nil, windGusts: Double? = nil, condition: WeatherCondition? = nil, conditionText: String? = nil,
                distanceKm: Double? = nil) {
        self.stationName = stationName
        self.observedAt = observedAt
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.feelsLikeKind = feelsLikeKind
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.windGusts = windGusts
        self.condition = condition
        self.conditionText = conditionText
        self.distanceKm = distanceKm
    }

    /// Stations closer than this stand in for the user's own spot: temperature, wind and feels-like.
    /// Farther ones only tell us what the sky is doing (rain, snow, fog).
    public static let localRadiusKm: Double = 10

    public var isLocal: Bool { (distanceKm ?? 0) <= Self.localRadiusKm }

    /// Farther than this, a station's reading isn't used for the temperature at all.
    public static let neighbourMaxKm: Double = 40

    /// How much of the models' error at a station beyond `localRadiusKm` is carried over to the
    /// spot: right now the models are often wrong the same way over a wide area (cloud they
    /// missed, a front running early, a cold pool after a clear night), but a station 30 km away
    /// is still a different place. Shares fitted at ~80 airports in metro areas on six
    /// continents, each region held out of its own fit (tools/score_neighbours.py, Nov 2026):
    /// error "now" fell from 0.97° to 0.87° on average and in every region; held-out shares
    /// came out nearly the same everywhere.
    public static func neighbourShare(distanceKm d: Double) -> Double {
        switch d {
        case ..<localRadiusKm: return 0
        case ..<20: return neighbourShares[0]
        case ..<35: return neighbourShares[1]
        case ...neighbourMaxKm: return neighbourShares[2]
        default: return 0
        }
    }
    static let neighbourShares: [Double] = [0.55, 0.45, 0.35]
    /// A gap bigger than this between a station and the models at the station is more likely a
    /// faulty reading or a very different spot (a mountain top) than shared weather.
    static let neighbourMaxGap: Double = 6

    /// Degrees to shift the spot's "now" by, from a station beyond `localRadiusKm` (nil if none).
    public var neighbourShift: Double? {
        guard !isLocal, dataProvider != "NETATMO", temperature.isFinite, let m = modelAtStation,
              let d = distanceKm else { return nil }
        let gap = temperature - m
        let k = Self.neighbourShare(distanceKm: d)
        guard k > 0, abs(gap) <= Self.neighbourMaxGap else { return nil }
        return k * gap
    }
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
        let (data, response) = try await loader(URLRequest(url: url, timeoutInterval: 8))
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
            URLQueryItem(name: "limit", value: "10"),
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
            windGusts: number(wind?["gust"]),
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

    public static func distanceKm(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

public extension Forecast {
    /// Replaces the model's "now" with a station observation where the station has data, and
    /// eases the next few forecast hours toward it (see `nudged(toward:at:)`).
    func applying(_ observation: Observation?) -> Forecast {
        guard var o = observation else { return self }
        o = tieBroken(o)
        var copy = self
        var c = current
        // A sky reported by a station far away (Pearson, 25 km from Milton) says nothing about
        // the sky here: it can be raining, snowing, foggy, cloudy or sunny there and not here.
        // Drop it and keep the forecast's sky for this spot, which the radar over this spot can
        // still turn wet below.
        if !o.skyIsLocal {
            o.condition = nil
            o.conditionText = nil
        }
        copy.observation = o
        if o.condition != nil {
            let name = o.skyStationName ?? o.stationName
            let km = o.skyStationName == nil ? o.distanceKm : o.skyDistanceKm
            copy.skySource = WeatherFormat.plainStationName(name)
                + (km.map { ", \(WeatherFormat.roughDistance($0)) away" } ?? "")
        }
        // A home station far from both its neighbours' official reading and the model is more
        // likely sitting in the sun than right; keep only its sky.
        // In daylight a home sensor in the sun can read 5-13° high (seen in Milton, 15 Nov at 11 am:
        // 6.3, 7.0, 8.4, 12.7 and 19.2° side by side). Sunshine only ever warms them, so by day
        // stations more than a little above the forecast are dropped and the rest decide.
        if o.dataProvider == "NETATMO", let temps = o.stationTemperatures, !temps.isEmpty {
            // At night there's no sun to heat them, and the models are the likelier ones to be off
            // (cloud they missed keeps it milder), so only a reading well above them is set aside.
            let limit = current.isDay ? Self.sunWarmLimit : Self.nightWarmLimit
            let shaded = temps.filter { $0 <= current.temperature + limit }
            if shaded.isEmpty {
                o.temperature = .infinity   // every station sun-heated: fall back to the forecast below
            } else if shaded.count < temps.count, let mid = Self.median(Array(shaded.prefix(3))) {
                o.temperature = (mid * 10).rounded() / 10
            }
        }
        let pwsLimit = (o.stationTemperatures?.count ?? 0) >= 2 ? 5.0 : 2.5
        let implausible = o.dataProvider == "NETATMO" && !(abs(o.temperature - current.temperature) <= pwsLimit)
        guard o.isLocal, !implausible else {
            // A distant station (a lakeshore pier, an airport across town) can't speak for the
            // user's temperature or wind, but it does tell us whether it's raining, and how far
            // off the models are around here right now (`neighbourShift`).
            c.condition = o.condition ?? c.condition
            if !implausible, let shift = o.neighbourShift, let base = forecastTemperature(at: o.observedAt) {
                c.temperature += shift
                c.feelsLike += shift
                copy.current = c
                copy.hourly = nudged(toward: Observation(stationName: "", observedAt: o.observedAt,
                                                         temperature: base + shift),
                                     fadeHours: Self.neighbourFadeHours)
                copy.daily = copy.dailyIncluding(c, at: c.time)
                return copy.dryIfGaugesSay(o)
            }
            copy.current = c
            return copy.dryIfGaugesSay(o)
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
        c.windGusts = o.windGusts ?? c.windGusts
        c.windDirection = o.windDirection ?? c.windDirection
        if let rain = o.rainLastHourMm { c.precipitation = rain }
        c.condition = o.condition ?? c.condition
        c.time = o.observedAt
        copy.current = c
        copy.hourly = nudged(toward: o)
        copy.daily = copy.dailyIncluding(c, at: o.observedAt)
        return copy.dryIfGaugesSay(o)
    }

    /// A tight group of home stations is allowed to stand against a road-weather station up to
    /// 4.5° away (`HyperlocalObservationProvider.merge`), but home stations as a group run warm on
    /// clear, still nights. When the two disagree by more than `tieBreakGap`, the side the models
    /// are closer to wins: the models' middle (the midpoint of their spread, which a station
    /// reading doesn't re-weight) at the time of the reading is the third opinion.
    func tieBroken(_ o: Observation) -> Observation {
        guard o.dataProvider == "NETATMO", let official = o.officialTemperature,
              abs(o.temperature - official) > HyperlocalObservationProvider.tieBreakGap else { return o }
        let low = forecastValue(at: o.observedAt) { $0.modelLow }
        let high = forecastValue(at: o.observedAt) { $0.modelHigh }
        let models = (low != nil && high != nil) ? (low! + high!) / 2 : forecastTemperature(at: o.observedAt)
        guard let models, abs(official - models) < abs(o.temperature - models) else { return o }
        var b = o
        b.temperature = official
        b.stationName = o.officialStationName ?? o.stationName
        b.distanceKm = o.officialDistanceKm
        b.dataProvider = o.officialProvider
        b.stationTemperatures = nil
        b.humidity = nil
        b.officialTemperature = nil
        return b
    }

    /// Rain from a distant station or the model, when the rain gauges right here are dry, becomes
    /// cloud. Snow is left alone: home gauges aren't heated and miss it.
    func dryIfGaugesSay(_ o: Observation) -> Forecast {
        guard o.gaugesSayDry, current.temperature > 1, current.condition.isRainLike else { return self }
        var copy = self
        copy.current.condition = .overcast
        copy.observation?.conditionText = nil
        return copy
    }

    /// Today's high and low widened to take in the reading and the eased hours, so the day never
    /// says 5° while it's 7° out.
    func dailyIncluding(_ now: CurrentConditions, at time: Date) -> [DailyForecast] {
        daily.map { day in
            let hours = self.hours(on: day)
            guard hours.contains(where: { abs($0.time.timeIntervalSince(time)) < 3600 }) else { return day }
            var d = day
            let temps = hours.map(\.temperature) + [now.temperature]
           let feels = hours.compactMap(\.feelsLike) + [now.feelsLike]
           if hours.count >= 18 {
               let hiAllow = extremesIncludePeak == true ? ModelBlend.highAllowance : 0
               let loAllow = extremesIncludePeak == true ? ModelBlend.lowAllowance : 0
               d.high = max(hours.map(\.temperature).max()! + hiAllow, now.temperature)
               d.low = min(hours.map(\.temperature).min()! - loAllow, now.temperature)
               if d.feelsLikeHigh != nil { d.feelsLikeHigh = feels.max() }
               if d.feelsLikeLow != nil { d.feelsLikeLow = feels.min() }
           } else {
                d.high = max(d.high, temps.max()!)
                d.low = min(d.low, temps.min()!)
                d.feelsLikeHigh = d.feelsLikeHigh.map { max($0, feels.max()!) }
                d.feelsLikeLow = d.feelsLikeLow.map { min($0, feels.min()!) }
           }
            return d
        }
    }

    /// Linearly interpolates a numeric hourly field at `time`.
    private func forecastValue(at time: Date, _ extract: (HourlyForecast) -> Double?) -> Double? {
        guard let i = hourly.lastIndex(where: { $0.time <= time }) else { return hourly.first.flatMap(extract) }
        let a = hourly[i]
        guard let va = extract(a) else { return nil }
        guard i + 1 < hourly.count, let vb = extract(hourly[i + 1]) else { return va }
        let span = hourly[i + 1].time.timeIntervalSince(a.time)
        guard span > 0 else { return va }
        let f = min(1, max(0, time.timeIntervalSince(a.time) / span))
        return va + (vb - va) * f
    }

    /// The hourly forecast's temperature at `time`, read between the two hours around it, so a
    /// reading at 11:15 is compared with the forecast for 11:15 and not with 11:00.
    func forecastTemperature(at time: Date) -> Double? {
        forecastValue(at: time) { $0.temperature }
    }

    /// Magnus dew point (°C) from temperature (°C) and relative humidity (%).
    private static func dewPoint(temperature t: Double, humidity rh: Double) -> Double {
        let clampedRH = min(100, max(1, rh))
        let a = 17.625, b = 243.04
        let gamma = log(clampedRH / 100.0) + (a * t) / (b + t)
        return min(t, (b * gamma) / (a - gamma))
    }

    /// Relative humidity (%) from temperature (°C) and dew point (°C).
    private static func relativeHumidity(temperature t: Double, dewPoint td: Double) -> Double {
        let a = 17.625, b = 243.04
        let rh = 100.0 * exp((a * td) / (b + td) - (a * t) / (b + t))
        return min(100, max(0, rh))
    }

    /// By day, home stations more than this above the forecast are taken to be in the sun.
    static let sunWarmLimit: Double = 2.5
    /// At night, a home station more than this above the forecast is taken to be by a warm wall.
    static let nightWarmLimit: Double = 4

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted()
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// How long a station reading keeps pulling the forecast toward it.
    static let nudgeHours: Double = 6
    /// How long a distant station's correction (`Observation.neighbourShift`) lasts. 12 h scored
    /// best (hours 1-12 error 0.99° vs 1.02° uncorrected); by then it's worth about nothing.
    static let neighbourFadeHours: Double = 12

    /// The hourly forecast shifted by the gap between a reading and the forecast for that time,
    /// fully at the reading and fading to nothing `nudgeHours` later, so the curve starts where
    /// the station is instead of jumping from it.
    func nudged(toward observed: Double, at time: Date) -> [HourlyForecast] {
        nudged(toward: Observation(stationName: "", observedAt: time, temperature: observed))
    }

    /// Nudges temperature, feels-like, dew point, humidity, and wind speed over the next
    /// `nudgeHours` toward `observation` so hourly curves stay physically consistent.
    func nudged(toward observation: Observation, fadeHours: Double = Forecast.nudgeHours) -> [HourlyForecast] {
        let time = observation.observedAt
        guard let baseTemp = forecastTemperature(at: time) else { return hourly }
        let tempGap = observation.temperature - baseTemp

        let obsHumidity = observation.humidity.map { min(100, max(0, $0)) }
        let obsDewPoint = obsHumidity.map { Self.dewPoint(temperature: observation.temperature, humidity: $0) }
        let baseHumidity = forecastValue(at: time) { $0.humidity }
        let baseDewPoint = forecastValue(at: time) { $0.dewPoint }
        let humidityGap = obsHumidity.flatMap { o in baseHumidity.map { o - $0 } }
        let dewPointGap = obsDewPoint.flatMap { o in baseDewPoint.map { o - $0 } }

        // Home wind sensors are usually sheltered and read low, so only an official station's
        // wind steers the next hours (the Now card still shows the home reading).
        let officialWind = observation.dataProvider != "NETATMO"
        let baseWind = forecastValue(at: time) { $0.windSpeed }
        let windGap = officialWind ? observation.windSpeed.flatMap { w in baseWind.map { w - $0 } } : nil

        let baseGusts = forecastValue(at: time) { $0.windGusts }
        let gustsGap = officialWind ? observation.windGusts.flatMap { g in baseGusts.map { g - $0 } } : nil

        return hourly.map { hour in
            let hoursAhead = hour.time.timeIntervalSince(time) / 3600
            guard hoursAhead > -1 else { return hour }
            let share = max(0, 1 - max(hoursAhead, 0) / fadeHours)
            guard share > 0 else { return hour }
            var h = hour
            h.temperature += tempGap * share
            h.feelsLike = h.feelsLike.map { $0 + tempGap * share }
            h.modelLow = h.modelLow.map { $0 + tempGap * share }
            h.modelHigh = h.modelHigh.map { $0 + tempGap * share }

            if let dpGap = dewPointGap, let dp = h.dewPoint {
                let nudgedDP = min(h.temperature, dp + dpGap * share)
                h.dewPoint = nudgedDP
                h.humidity = Self.relativeHumidity(temperature: h.temperature, dewPoint: nudgedDP)
            } else if let humGap = humidityGap, let hum = h.humidity {
                let nudgedHum = min(100, max(0, hum + humGap * share))
                h.humidity = nudgedHum
                if h.dewPoint != nil {
                    h.dewPoint = Self.dewPoint(temperature: h.temperature, humidity: nudgedHum)
                }
            }

            if let wGap = windGap, let w = h.windSpeed {
                h.windSpeed = max(0, w + wGap * share)
            }
            if let gGap = gustsGap, let g = h.windGusts {
                h.windGusts = max(h.windSpeed ?? 0, g + gGap * share)
            }
            return h
        }
    }
}
