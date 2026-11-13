import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Global forecasts from Open-Meteo (https://open-meteo.com).
/// Free for non-commercial use, no API key. Data licensed CC BY 4.0, so the UI must show `attribution`.
public struct OpenMeteoProvider: ForecastProvider {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let name = "Open-Meteo"
    public let attribution = "Weather data by Open-Meteo.com (CC BY 4.0)"

    private let baseURL: URL
    private let forecastDays: Int
    private let loader: DataLoader

    public init(
        baseURL: URL = URL(string: "https://api.open-meteo.com/v1/forecast")!,
        forecastDays: Int = 10,
        loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.forecastDays = forecastDays
        self.loader = loader
    }

    public func forecast(for coordinate: Coordinate) async throws -> Forecast {
        let request = URLRequest(url: url(for: coordinate), timeoutInterval: 20)
        let (data, response) = try await loader(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return try Self.parse(data, fetchedAt: Date())
    }

    static let currentFields = [
        "temperature_2m", "apparent_temperature", "relative_humidity_2m", "is_day",
        "precipitation", "weather_code", "wind_speed_10m", "wind_direction_10m",
    ]
    static let hourlyFields = [
        "temperature_2m", "apparent_temperature", "precipitation_probability", "weather_code", "is_day",
    ]
    static let dailyFields = [
        "weather_code", "temperature_2m_max", "temperature_2m_min",
        "apparent_temperature_max", "apparent_temperature_min", "precipitation_probability_max",
    ]

    func url(for coordinate: Coordinate) -> URL {
        let c = coordinate.rounded
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(c.latitude)),
            URLQueryItem(name: "longitude", value: String(c.longitude)),
            URLQueryItem(name: "current", value: Self.currentFields.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: Self.hourlyFields.joined(separator: ",")),
            URLQueryItem(name: "daily", value: Self.dailyFields.joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]
        return components.url!
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> Forecast {
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let temperature = r.current.temperature else { throw ForecastError.missingData("current temperature") }

        let current = CurrentConditions(
            time: Date(timeIntervalSince1970: TimeInterval(r.current.time)),
            temperature: temperature,
            feelsLike: r.current.apparentTemperature ?? temperature,
            feelsLikeKind: .apparent,
            humidity: r.current.relativeHumidity,
            windSpeed: r.current.windSpeed,
            windDirection: r.current.windDirection,
            precipitation: r.current.precipitation,
            condition: WeatherCondition(wmoCode: r.current.weatherCode),
            isDay: (r.current.isDay ?? 1) == 1
        )

        var hourly: [HourlyForecast] = []
        if let h = r.hourly {
            for (i, time) in h.time.enumerated() {
                guard let temp = h.temperature.value(at: i) else { continue }
                hourly.append(HourlyForecast(
                    time: Date(timeIntervalSince1970: TimeInterval(time)),
                    temperature: temp,
                    feelsLike: h.apparentTemperature.value(at: i),
                    precipitationProbability: h.precipitationProbability.value(at: i),
                    condition: WeatherCondition(wmoCode: h.weatherCode.value(at: i)),
                    isDay: (h.isDay.value(at: i) ?? 1) == 1
                ))
            }
        }

        var daily: [DailyForecast] = []
        if let d = r.daily {
            for (i, time) in d.time.enumerated() {
                guard let high = d.temperatureMax.value(at: i), let low = d.temperatureMin.value(at: i) else { continue }
                daily.append(DailyForecast(
                    date: Date(timeIntervalSince1970: TimeInterval(time)),
                    high: high,
                    low: low,
                    feelsLikeHigh: d.apparentTemperatureMax.value(at: i),
                    feelsLikeLow: d.apparentTemperatureMin.value(at: i),
                    precipitationProbability: d.precipitationProbabilityMax.value(at: i),
                    condition: WeatherCondition(wmoCode: d.weatherCode.value(at: i))
                ))
            }
        }

        return Forecast(
            location: Coordinate(latitude: r.latitude, longitude: r.longitude),
            timeZoneIdentifier: r.timezone ?? TimeZone.current.identifier,
            current: current,
            hourly: hourly,
            daily: daily,
            source: "Open-Meteo",
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Wire format

    struct Response: Decodable {
        let latitude: Double
        let longitude: Double
        let timezone: String?
        let current: Current
        let hourly: Hourly?
        let daily: Daily?
    }

    struct Current: Decodable {
        let time: Int
        let temperature: Double?
        let apparentTemperature: Double?
        let relativeHumidity: Double?
        let isDay: Int?
        let precipitation: Double?
        let weatherCode: Int?
        let windSpeed: Double?
        let windDirection: Double?

        enum CodingKeys: String, CodingKey {
            case time, precipitation
            case temperature = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case relativeHumidity = "relative_humidity_2m"
            case isDay = "is_day"
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
            case windDirection = "wind_direction_10m"
        }
    }

    struct Hourly: Decodable {
        let time: [Int]
        let temperature: [Double?]?
        let apparentTemperature: [Double?]?
        let precipitationProbability: [Double?]?
        let weatherCode: [Int?]?
        let isDay: [Int?]?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case precipitationProbability = "precipitation_probability"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let time: [Int]
        let weatherCode: [Int?]?
        let temperatureMax: [Double?]?
        let temperatureMin: [Double?]?
        let apparentTemperatureMax: [Double?]?
        let apparentTemperatureMin: [Double?]?
        let precipitationProbabilityMax: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case apparentTemperatureMax = "apparent_temperature_max"
            case apparentTemperatureMin = "apparent_temperature_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }
}

private extension Optional {
    /// Safe lookup into an optional array of optionals, as Open-Meteo returns them.
    func value<T>(at index: Int) -> T? where Wrapped == [T?] {
        guard let array = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
