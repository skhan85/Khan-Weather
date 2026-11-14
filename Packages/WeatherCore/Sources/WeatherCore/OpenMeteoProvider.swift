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
        // In North America, temperatures are a weighted blend of several models (see ModelBlend).
        // Everything else stays on Open-Meteo's default.
        async let blended = Self.usesBlend(coordinate) ? blendedTemperatures(for: coordinate) : nil
        let request = URLRequest(url: url(for: coordinate), timeoutInterval: 20)
        let (data, response) = try await loader(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        let forecast = try Self.parse(data, fetchedAt: Date())
        guard let temps = await blended else { return forecast }
        return forecast.applying(temps)
    }

    /// North America, where the high-resolution Canadian and US models cover the spot.
    static func usesBlend(_ c: Coordinate) -> Bool {
        (24...84).contains(c.latitude) && (-170...(-52)).contains(c.longitude)
    }

    /// Blended hourly temperatures. nil if the request fails, so the default stays.
    func blendedTemperatures(for coordinate: Coordinate, now: Date = Date()) async -> ModelTemperatures? {
        let request = URLRequest(url: blendURL(for: coordinate), timeoutInterval: 15)
        guard let (data, response) = try? await loader(request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return try? Self.parseBlend(data, now: now)
    }

    func blendURL(for coordinate: Coordinate) -> URL {
        let c = coordinate.rounded
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(c.latitude)),
            URLQueryItem(name: "longitude", value: String(c.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature"),
            URLQueryItem(name: "models", value: ModelBlend.members.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]
        return components.url!
    }

    /// Blended temperatures keyed by hour, to lay over the default forecast.
    struct ModelTemperatures {
        var hourly: [Int: (temperature: Double, feelsLike: Double?)] = [:]
    }

    /// With several models, Open-Meteo suffixes each field: "temperature_2m_gem_seamless".
    static func parseBlend(_ data: Data, now: Date) throws -> ModelTemperatures {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [NSNumber] else { throw ForecastError.missingData("hourly") }
        func series(_ field: String, _ model: WeatherModel) -> [Double?] {
            ((hourly["\(field)_\(model.rawValue)"] as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }
        let temps = Dictionary(uniqueKeysWithValues: ModelBlend.members.map { ($0, series("temperature_2m", $0)) })
        let feels = Dictionary(uniqueKeysWithValues: ModelBlend.members.map { ($0, series("apparent_temperature", $0)) })
        var out = ModelTemperatures()
        for (i, t) in times.enumerated() {
            let lead = (t.doubleValue - now.timeIntervalSince1970) / 3600
            func at(_ s: [WeatherModel: [Double?]]) -> [WeatherModel: Double] {
                s.compactMapValues { i < $0.count ? $0[i] : nil }
            }
            guard let temp = ModelBlend.blend(at(temps), leadHours: lead) else { continue }
            out.hourly[t.intValue] = (temp, ModelBlend.blend(at(feels), leadHours: lead))
        }
        return out
    }

    static let currentFields = [
        "temperature_2m", "apparent_temperature", "relative_humidity_2m", "is_day",
        "precipitation", "weather_code", "wind_speed_10m", "wind_direction_10m",
        "pressure_msl", "wind_gusts_10m",
    ]
    static let hourlyFields = [
        "temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation",
        "weather_code", "is_day", "relative_humidity_2m", "dew_point_2m", "wind_speed_10m",
        "wind_gusts_10m", "wind_direction_10m", "uv_index", "rain", "showers", "snowfall", "visibility",
    ]
    static let dailyFields = [
        "weather_code", "temperature_2m_max", "temperature_2m_min",
        "apparent_temperature_max", "apparent_temperature_min", "precipitation_probability_max",
        "rain_sum", "showers_sum", "snowfall_sum", "sunrise", "sunset", "uv_index_max",
        "wind_speed_10m_max", "wind_gusts_10m_max", "wind_direction_10m_dominant", "precipitation_hours",
    ]
    static let minutelyFields = ["precipitation", "rain", "snowfall"]

    func url(for coordinate: Coordinate) -> URL {
        let c = coordinate.rounded
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(c.latitude)),
            URLQueryItem(name: "longitude", value: String(c.longitude)),
            URLQueryItem(name: "current", value: Self.currentFields.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: Self.hourlyFields.joined(separator: ",")),
            URLQueryItem(name: "daily", value: Self.dailyFields.joined(separator: ",")),
            URLQueryItem(name: "minutely_15", value: Self.minutelyFields.joined(separator: ",")),
            // 3 hours, so the 2-hour nowcast window is still covered if the request is a bit late.
            URLQueryItem(name: "forecast_minutely_15", value: "12"),
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
            isDay: (r.current.isDay ?? 1) == 1,
            pressure: r.current.pressure,
            windGusts: r.current.windGusts
        )

        var hourly: [HourlyForecast] = []
        if let h = r.hourly {
            for (i, time) in h.time.enumerated() {
                guard let temp = h.temperature.value(at: i) else { continue }
                var hour = HourlyForecast(
                    time: Date(timeIntervalSince1970: TimeInterval(time)),
                    temperature: temp,
                    feelsLike: h.apparentTemperature.value(at: i),
                    precipitationProbability: h.precipitationProbability.value(at: i),
                    precipitation: h.precipitation.value(at: i),
                    condition: WeatherCondition(wmoCode: h.weatherCode.value(at: i))
                        .ignoringTrace(probability: h.precipitationProbability.value(at: i),
                                       amountMm: h.precipitation.value(at: i)),
                    isDay: (h.isDay.value(at: i) ?? 1) == 1
                )
                hour.humidity = h.relativeHumidity.value(at: i)
                hour.dewPoint = h.dewPoint.value(at: i)
                hour.windSpeed = h.windSpeed.value(at: i)
                hour.windGusts = h.windGusts.value(at: i)
                hour.windDirection = h.windDirection.value(at: i)
                hour.uvIndex = h.uvIndex.value(at: i)
                hour.rain = Self.sum(h.rain.value(at: i), h.showers.value(at: i))
                hour.snowfall = h.snowfall.value(at: i)
                hour.visibility = h.visibility.value(at: i)
                hourly.append(hour)
            }
        }

        var daily: [DailyForecast] = []
        if let d = r.daily {
            for (i, time) in d.time.enumerated() {
                guard let high = d.temperatureMax.value(at: i), let low = d.temperatureMin.value(at: i) else { continue }
                let rain = Self.sum(d.rainSum.value(at: i), d.showersSum.value(at: i))
                let snow = d.snowfallSum.value(at: i)
                // Snow cm and rain mm are added only to judge "is this a trace".
                let total = rain == nil && snow == nil ? nil : (rain ?? 0) + (snow ?? 0)
                var day = DailyForecast(
                    date: Date(timeIntervalSince1970: TimeInterval(time)),
                    high: high,
                    low: low,
                    feelsLikeHigh: d.apparentTemperatureMax.value(at: i),
                    feelsLikeLow: d.apparentTemperatureMin.value(at: i),
                    precipitationProbability: d.precipitationProbabilityMax.value(at: i),
                    condition: WeatherCondition(wmoCode: d.weatherCode.value(at: i))
                        .ignoringTrace(probability: d.precipitationProbabilityMax.value(at: i), amountMm: total),
                    rainSum: rain,
                    snowfallSum: snow
                )
                day.sunrise = d.sunrise.value(at: i).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                day.sunset = d.sunset.value(at: i).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                day.uvIndexMax = d.uvIndexMax.value(at: i)
                day.windSpeedMax = d.windSpeedMax.value(at: i)
                day.windGustsMax = d.windGustsMax.value(at: i)
                day.windDirectionDominant = d.windDirectionDominant.value(at: i)
                day.precipitationHours = d.precipitationHours.value(at: i)
                daily.append(day)
            }
        }

        var minutely: [PrecipitationSlot] = []
        if let m = r.minutely15 {
            for (i, time) in m.time.enumerated() {
                guard let p = m.precipitation.value(at: i) else { continue }
                minutely.append(PrecipitationSlot(
                    time: Date(timeIntervalSince1970: TimeInterval(time)),
                    precipitation: p,
                    rain: m.rain.value(at: i) ?? 0,
                    snowfall: m.snowfall.value(at: i) ?? 0
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
            fetchedAt: fetchedAt,
            minutely: minutely
        ).withDailyHeadlines()
    }

    /// Adds two optional amounts; nil only when both are missing.
    static func sum(_ a: Double?, _ b: Double?) -> Double? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    // MARK: - Wire format

    struct Response: Decodable {
        let latitude: Double
        let longitude: Double
        let timezone: String?
        let current: Current
        let hourly: Hourly?
        let daily: Daily?
        let minutely15: Minutely15?

        enum CodingKeys: String, CodingKey {
            case latitude, longitude, timezone, current, hourly, daily
            case minutely15 = "minutely_15"
        }
    }

    struct Minutely15: Decodable {
        let time: [Int]
        let precipitation: [Double?]?
        let rain: [Double?]?
        let snowfall: [Double?]?
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
        let pressure: Double?
        let windGusts: Double?

        enum CodingKeys: String, CodingKey {
            case time, precipitation
            case pressure = "pressure_msl"
            case windGusts = "wind_gusts_10m"
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
        let precipitation: [Double?]?
        let weatherCode: [Int?]?
        let isDay: [Int?]?
        let relativeHumidity: [Double?]?
        let dewPoint: [Double?]?
        let windSpeed: [Double?]?
        let windGusts: [Double?]?
        let windDirection: [Double?]?
        let uvIndex: [Double?]?
        let rain: [Double?]?
        let showers: [Double?]?
        let snowfall: [Double?]?
        let visibility: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time, precipitation, rain, showers, snowfall, visibility
            case relativeHumidity = "relative_humidity_2m"
            case dewPoint = "dew_point_2m"
            case windSpeed = "wind_speed_10m"
            case windGusts = "wind_gusts_10m"
            case windDirection = "wind_direction_10m"
            case uvIndex = "uv_index"
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
        let rainSum: [Double?]?
        let showersSum: [Double?]?
        let snowfallSum: [Double?]?
        let sunrise: [Int?]?
        let sunset: [Int?]?
        let uvIndexMax: [Double?]?
        let windSpeedMax: [Double?]?
        let windGustsMax: [Double?]?
        let windDirectionDominant: [Double?]?
        let precipitationHours: [Double?]?

        enum CodingKeys: String, CodingKey {
            case sunrise, sunset
            case uvIndexMax = "uv_index_max"
            case windSpeedMax = "wind_speed_10m_max"
            case windGustsMax = "wind_gusts_10m_max"
            case windDirectionDominant = "wind_direction_10m_dominant"
            case precipitationHours = "precipitation_hours"
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case apparentTemperatureMax = "apparent_temperature_max"
            case apparentTemperatureMin = "apparent_temperature_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
            case rainSum = "rain_sum"
            case showersSum = "showers_sum"
            case snowfallSum = "snowfall_sum"
        }
    }
}

extension Forecast {
    /// Swaps in blended temperatures wherever they cover an hour, then recomputes each fully
    /// covered day's high and low from those hours (Open-Meteo builds its daily values the same way).
    func applying(_ temps: OpenMeteoProvider.ModelTemperatures) -> Forecast {
        var copy = self
        copy.hourly = hourly.map { hour in
            var h = hour
            if let t = temps.hourly[Int(hour.time.timeIntervalSince1970)] {
                h.temperature = t.temperature
                h.feelsLike = t.feelsLike ?? h.feelsLike
            }
            return h
        }
        copy.daily = daily.map { day in
            var d = day
            let hours = copy.hours(on: day).filter { temps.hourly[Int($0.time.timeIntervalSince1970)] != nil }
            guard hours.count >= 23 else { return d }   // 23 allows the short day when clocks change
            d.high = hours.map(\.temperature).max()!
            d.low = hours.map(\.temperature).min()!
            let feels = hours.compactMap(\.feelsLike)
            if feels.count == hours.count {
                d.feelsLikeHigh = feels.max()
                d.feelsLikeLow = feels.min()
            }
            return d
        }
        return copy
    }
}

private extension Optional {
    /// Safe lookup into an optional array of optionals, as Open-Meteo returns them.
    func value<T>(at index: Int) -> T? where Wrapped == [T?] {
        guard let array = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
