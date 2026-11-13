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

    public init(time: Date, temperature: Double, feelsLike: Double, feelsLikeKind: FeelsLikeKind,
                humidity: Double? = nil, windSpeed: Double? = nil, windDirection: Double? = nil,
                precipitation: Double? = nil, condition: WeatherCondition, isDay: Bool) {
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
    public var condition: WeatherCondition
    /// False between sunset and sunrise, so clear hours show a moon instead of a sun.
    public var isDay: Bool
    public var id: Date { time }

    public init(time: Date, temperature: Double, feelsLike: Double? = nil,
                precipitationProbability: Double? = nil, condition: WeatherCondition, isDay: Bool = true) {
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
    public var id: Date { date }

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
