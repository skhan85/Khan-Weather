import Foundation

/// A point on Earth. Rounded to 4 decimals (about 11 m) before it is sent to any provider.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Used when location access is denied or not yet available.
    public static let fallback = Coordinate(latitude: 43.6532, longitude: -79.3832) // Toronto

    var rounded: Coordinate {
        Coordinate(latitude: (latitude * 10_000).rounded() / 10_000,
                   longitude: (longitude * 10_000).rounded() / 10_000)
    }
}

/// Which formula the provider used for "feels like", so the UI can label it.
public enum FeelsLikeKind: String, Codable, Sendable {
    case apparent   // Open-Meteo, WeatherKit-style apparent temperature
    case humidex    // Environment Canada, summer
    case windChill  // Environment Canada, winter
}

public struct CurrentConditions: Equatable, Codable, Sendable {
    public var time: Date
    public var temperature: Double
    public var feelsLike: Double
    public var feelsLikeKind: FeelsLikeKind
    public var humidity: Double?
    public var windSpeed: Double?       // km/h
    public var windDirection: Double?   // degrees
    public var precipitation: Double?   // mm
    public var condition: WeatherCondition
    public var isDay: Bool
    /// Sea-level pressure, hPa.
    public var pressure: Double?
    public var windGusts: Double?       // km/h

    public init(time: Date, temperature: Double, feelsLike: Double, feelsLikeKind: FeelsLikeKind,
                humidity: Double? = nil, windSpeed: Double? = nil, windDirection: Double? = nil,
                precipitation: Double? = nil, condition: WeatherCondition, isDay: Bool,
                pressure: Double? = nil, windGusts: Double? = nil) {
        self.pressure = pressure
        self.windGusts = windGusts
        self.time = time
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.feelsLikeKind = feelsLikeKind
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.precipitation = precipitation
        self.condition = condition
        self.isDay = isDay
    }
}

public struct HourlyForecast: Equatable, Codable, Sendable, Identifiable {
    public var time: Date
    public var temperature: Double
    public var feelsLike: Double?
    public var precipitationProbability: Double?
    /// Precipitation in the hour, mm.
    public var precipitation: Double?
    public var condition: WeatherCondition
    /// False between sunset and sunrise, so clear hours show a moon instead of a sun.
    public var isDay: Bool
    // Detail fields, shown when the hour is tapped. All optional.
    public var humidity: Double?
    public var dewPoint: Double?
    /// km/h
    public var windSpeed: Double?
    /// km/h
    public var windGusts: Double?
    /// Degrees the wind comes from.
    public var windDirection: Double?
    public var uvIndex: Double?
    /// mm
    public var rain: Double?
    /// cm
    public var snowfall: Double?
    /// metres
    public var visibility: Double?
    public var id: Date { time }

    /// What a precipitation chance for this hour would be.
    public var precipitationKind: PrecipitationKind {
        PrecipitationKind.guess(rain: rain, snow: snowfall, condition: condition,
                                low: temperature, high: temperature)
    }

    public init(time: Date, temperature: Double, feelsLike: Double? = nil,
                precipitationProbability: Double? = nil, precipitation: Double? = nil,
                condition: WeatherCondition, isDay: Bool = true) {
        self.precipitation = precipitation
        self.time = time
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.precipitationProbability = precipitationProbability
        self.condition = condition
        self.isDay = isDay
    }
}

public struct DailyForecast: Equatable, Codable, Sendable, Identifiable {
    public var date: Date
    public var high: Double
    public var low: Double
    public var feelsLikeHigh: Double?
    public var feelsLikeLow: Double?
    public var precipitationProbability: Double?
    public var condition: WeatherCondition
    /// Total rain and showers for the day, in mm.
    public var rainSum: Double?
    /// Total snowfall for the day, in cm.
    public var snowfallSum: Double?
    /// "Rain then snow" and the like, when one word doesn't cover the day.
    public var summary: String?
    // Detail fields, shown when the day is tapped. All optional.
    public var sunrise: Date?
    public var sunset: Date?
    public var uvIndexMax: Double?
    /// km/h
    public var windSpeedMax: Double?
    /// km/h
    public var windGustsMax: Double?
    public var windDirectionDominant: Double?
    public var precipitationHours: Double?
    public var id: Date { date }

    /// What the day's precipitation chance is a chance of.
    public var precipitationKind: PrecipitationKind {
        PrecipitationKind.guess(rain: rainSum, snow: snowfallSum, condition: condition, low: low, high: high)
    }

    public init(date: Date, high: Double, low: Double, feelsLikeHigh: Double? = nil, feelsLikeLow: Double? = nil,
                precipitationProbability: Double? = nil, condition: WeatherCondition,
                rainSum: Double? = nil, snowfallSum: Double? = nil) {
        self.date = date
        self.high = high
        self.low = low
        self.feelsLikeHigh = feelsLikeHigh
        self.feelsLikeLow = feelsLikeLow
        self.precipitationProbability = precipitationProbability
        self.condition = condition
        self.rainSum = rainSum
        self.snowfallSum = snowfallSum
    }
}

/// Fifteen minutes of precipitation from the short-range forecast, used for "rain starting in 20 min".
public struct PrecipitationSlot: Equatable, Codable, Sendable {
    /// Start of the 15-minute period.
    public var time: Date
    /// Total precipitation in mm (water equivalent).
    public var precipitation: Double
    /// Rain in mm.
    public var rain: Double
    /// Snowfall in cm.
    public var snowfall: Double

    public init(time: Date, precipitation: Double, rain: Double = 0, snowfall: Double = 0) {
        self.time = time
        self.precipitation = precipitation
        self.rain = rain
        self.snowfall = snowfall
    }

    /// Below this a slot counts as dry; 0.1 mm per 15 min is about the lightest drizzle a gauge records.
    static let wetThreshold = 0.1
    var isWet: Bool { precipitation >= Self.wetThreshold || snowfall >= 0.1 }
}

public struct Forecast: Equatable, Codable, Sendable {
    public var location: Coordinate
    public var timeZoneIdentifier: String
    public var current: CurrentConditions
    public var hourly: [HourlyForecast]
    public var daily: [DailyForecast]
    public var source: String
    public var fetchedAt: Date
    /// Set when `current` comes from a real station observation rather than the forecast model.
    public var observation: Observation?
    /// The next couple of hours in 15-minute steps. Empty if the provider has none.
    public var minutely: [PrecipitationSlot]
    /// Set when the radar changed "now" (rain or snow falling here).
    public var radar: RadarNow?

    public init(location: Coordinate, timeZoneIdentifier: String, current: CurrentConditions,
                hourly: [HourlyForecast], daily: [DailyForecast], source: String, fetchedAt: Date,
                observation: Observation? = nil, minutely: [PrecipitationSlot] = []) {
        self.location = location
        self.timeZoneIdentifier = timeZoneIdentifier
        self.current = current
        self.hourly = hourly
        self.daily = daily
        self.source = source
        self.fetchedAt = fetchedAt
        self.observation = observation
        self.minutely = minutely
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// The next `count` hours, starting with the hour that contains `date`.
    public func upcomingHours(from date: Date = Date(), count: Int = 24) -> [HourlyForecast] {
        Array(hourly.filter { $0.time.addingTimeInterval(3600) > date }.prefix(count))
    }

    /// The next hours, with the first one showing current conditions (the same numbers as the
    /// "now" card, which may come from a nearby station) instead of the forecast for that hour.
    public func hoursStartingNow(from date: Date = Date(), count: Int = 24) -> [HourlyForecast] {
        var hours = upcomingHours(from: date, count: count)
        guard !hours.isEmpty else { return hours }
        let c = current
        hours[0].temperature = c.temperature
        hours[0].feelsLike = c.feelsLike
        hours[0].condition = c.condition
        hours[0].isDay = c.isDay
        hours[0].humidity = c.humidity ?? hours[0].humidity
        hours[0].windSpeed = c.windSpeed ?? hours[0].windSpeed
        hours[0].windDirection = c.windDirection ?? hours[0].windDirection
        hours[0].windGusts = c.windGusts ?? hours[0].windGusts
        return hours
    }

    /// The forecast hour that contains `date`, for values the "now" request doesn't carry
    /// (UV, visibility, dew point).
    public func hour(at date: Date = Date()) -> HourlyForecast? {
        upcomingHours(from: date, count: 1).first
    }

    /// Today's row of the daily forecast, in the place's time zone.
    public func day(at date: Date = Date()) -> DailyForecast? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return daily.first { calendar.isDate($0.date, inSameDayAs: date) } ?? daily.first
    }
}

public enum ForecastError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case missingData(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "The weather service returned HTTP \(code)."
        case .missingData(let field): return "The weather service response was missing \(field)."
        }
    }
}

/// Anything that can produce a forecast for a coordinate.
public protocol ForecastProvider: Sendable {
    var name: String { get }
    var attribution: String { get }
    func forecast(for coordinate: Coordinate) async throws -> Forecast
}

/// Rain, snow, or either, so a "40%" can say what it's a chance of.
public enum PrecipitationKind: String, Codable, Sendable {
    case rain, snow, mixed

    /// SF Symbol shown next to the percentage.
    public var symbolName: String {
        switch self {
        case .rain: return "drop.fill"
        case .snow: return "snowflake"
        case .mixed: return "cloud.sleet.fill"
        }
    }

    /// "rain", "snow", "rain or snow".
    public var noun: String {
        switch self {
        case .rain: return "rain"
        case .snow: return "snow"
        case .mixed: return "rain or snow"
        }
    }

    /// Uses forecast amounts when there are any, then the condition, then temperature.
    static func guess(rain: Double?, snow: Double?, condition: WeatherCondition,
                      low: Double, high: Double) -> PrecipitationKind {
        let r = rain ?? 0, s = snow ?? 0
        if r > 0 && s > 0 { return .mixed }
        if s > 0 { return .snow }
        if r > 0 { return .rain }
        switch condition {
        case .snow, .snowGrains, .snowShowers: return .snow
        case .freezingRain, .freezingDrizzle: return .mixed
        case .rain, .rainShowers, .drizzle, .thunderstorm, .thunderstormHail: return .rain
        default: break
        }
        if high <= 1 { return .snow }
        if low >= 3 { return .rain }
        return .mixed
    }
}

public extension Forecast {
    /// The hours that fall on `day`'s date in the forecast's time zone.
    func hours(on day: DailyForecast) -> [HourlyForecast] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return hourly.filter { calendar.isDate($0.time, inSameDayAs: day.date) }
    }
}

public extension Forecast {
    /// Below this chance a day isn't headlined as rain or snow, even if the model has a few wet hours.
    static let headlineChance: Double = 35

    /// Open-Meteo's daily weather code is the worst hour of the day, so a brief overnight flurry
    /// makes a 13° day say "Snow". Re-pick each day's headline from its hours.
    func withDailyHeadlines() -> Forecast {
        var copy = self
        copy.daily = daily.map { day in
            var d = day
            let hours = self.hours(on: day)
            guard d.condition.isPrecipitation || d.condition == .thunderstorm || d.condition == .thunderstormHail,
                  !hours.isEmpty else { return d }
            if (d.precipitationProbability ?? 100) < Self.headlineChance {
                d.condition = Self.dryHeadline(hours)
                return d
            }
            // Which kind falls when, from the wet hours.
            let wet = hours.filter { ($0.precipitation ?? 0) >= 0.1 || ($0.snowfall ?? 0) > 0 || ($0.rain ?? 0) > 0 }
            let kinds = wet.map { h -> PrecipitationKind in
                if (h.snowfall ?? 0) > 0 && (h.rain ?? 0) <= 0 { return .snow }
                if (h.rain ?? 0) > 0 && (h.snowfall ?? 0) <= 0 { return .rain }
                return h.temperature <= 1 ? .snow : .rain
            }
            guard let first = kinds.first, let last = kinds.last else { return d }
            let hasRain = kinds.contains(.rain), hasSnow = kinds.contains(.snow)
            if hasRain && hasSnow {
                d.summary = first == .rain && last == .snow ? "Rain then snow"
                    : first == .snow && last == .rain ? "Snow then rain" : "Rain and snow"
                let snowHours = kinds.filter { $0 == .snow }.count
                d.condition = snowHours * 2 > kinds.count ? .snow : .rain
            } else if hasRain, d.condition == .snow || d.condition == .snowShowers || d.condition == .snowGrains {
                d.condition = .rain
            } else if hasSnow, d.condition == .rain || d.condition == .rainShowers || d.condition == .drizzle {
                d.condition = .snow
            }
            return d
        }
        return copy
    }

    /// The most common sky among the day's daylight hours, ignoring the odd wet one.
    private static func dryHeadline(_ hours: [HourlyForecast]) -> WeatherCondition {
        let pool = hours.filter(\.isDay).isEmpty ? hours : hours.filter(\.isDay)
        var counts: [WeatherCondition: Int] = [:]
        for h in pool where !h.condition.isPrecipitation { counts[h.condition, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key ?? .overcast
    }
}

