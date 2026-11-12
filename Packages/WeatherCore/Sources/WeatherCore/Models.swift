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
}

public struct HourlyForecast: Equatable, Codable, Sendable, Identifiable {
    public var time: Date
    public var temperature: Double
    public var feelsLike: Double?
    public var precipitationProbability: Double?
    public var condition: WeatherCondition
    public var id: Date { time }
}

public struct DailyForecast: Equatable, Codable, Sendable, Identifiable {
    public var date: Date
    public var high: Double
    public var low: Double
    public var feelsLikeHigh: Double?
    public var feelsLikeLow: Double?
    public var precipitationProbability: Double?
    public var condition: WeatherCondition
    public var id: Date { date }
}

public struct Forecast: Equatable, Codable, Sendable {
    public var location: Coordinate
    public var timeZoneIdentifier: String
    public var current: CurrentConditions
    public var hourly: [HourlyForecast]
    public var daily: [DailyForecast]
    public var source: String
    public var fetchedAt: Date

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
