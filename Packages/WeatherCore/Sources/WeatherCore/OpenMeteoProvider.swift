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
        try await forecast(for: coordinate, anchor: { nil })
    }

    public func forecast(for coordinate: Coordinate, anchor: ModelBlend.Anchor?) async throws -> Forecast {
        try await forecast(for: coordinate, anchor: { anchor })
    }

    /// `anchor` gives the local station temperature that re-weights the first hours of the blend
    /// (see `ModelBlend.blend`). It is awaited only once the model data has arrived, so a slow
    /// station overlaps the download instead of adding to it.
    public func forecast(for coordinate: Coordinate,
                         anchor: @escaping @Sendable () async -> ModelBlend.Anchor?) async throws -> Forecast {
        // In North America, temperatures are a weighted blend of several models (see ModelBlend).
        // Everything else stays on Open-Meteo's default.
        async let blended = Self.usesBlend(coordinate)
            ? blendedTemperatures(for: coordinate, anchor: anchor)
            : nil
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
    func blendedTemperatures(for coordinate: Coordinate,
                             anchor: @Sendable () async -> ModelBlend.Anchor? = { nil }) async -> ModelTemperatures? {
        let request = URLRequest(url: blendURL(for: coordinate), timeoutInterval: 15)
        guard let (data, response) = try? await loader(request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let observed = await anchor()
        return try? Self.parseBlend(data, anchor: observed, now: Date())
    }

    func blendURL(for coordinate: Coordinate) -> URL {
        let c = coordinate.rounded
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(c.latitude)),
            URLQueryItem(name: "longitude", value: String(c.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation"),
            URLQueryItem(name: "models", value: ModelBlend.members.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
            // Yesterday too, for "colder than yesterday" and the pressure trend. Split off in `parse`.
            URLQueryItem(name: "past_days", value: "1"),
        ]
        return components.url!
    }

    /// Blended temperatures keyed by hour, to lay over the default forecast.
    struct ModelTemperatures {
        struct Hour {
            var temperature: Double
            var feelsLike: Double?
            var low: Double
            var high: Double
            var count: Int
            var wet: Int
            var freezing: Int
            /// Each model's precipitation (mm) this hour, for the day's chance of rain.
            var precipitation: [WeatherModel: Double] = [:]
        }
        var hourly: [Int: Hour] = [:]
    }

    /// Each series' value at `epoch`, interpolated between the two hours around it (or the nearest
    /// end when `epoch` is outside the hours).
    static func valuesAt(_ epoch: Double, times: [Double],
                         series: [WeatherModel: [Double?]]) -> [WeatherModel: Double] {
        guard !times.isEmpty else { return [:] }
        let after = times.firstIndex { $0 >= epoch } ?? times.count - 1
        let before = max(0, times[after] > epoch ? after - 1 : after)
        let span = times[after] - times[before]
        let f = span > 0 ? min(1, max(0, (epoch - times[before]) / span)) : 0
        return series.compactMapValues { s in
            guard after < s.count, let a = s[before], let b = s[after] else {
                return before < s.count ? s[before] : nil
            }
            return a + (b - a) * f
        }
    }

    /// With several models, Open-Meteo suffixes each field: "temperature_2m_gem_seamless".
    static func parseBlend(_ data: Data,
                           anchor: ModelBlend.Anchor? = nil,
                           now: Date) throws -> ModelTemperatures {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [NSNumber] else { throw ForecastError.missingData("hourly") }
        func series(_ field: String, _ model: WeatherModel) -> [Double?] {
            ((hourly["\(field)_\(model.rawValue)"] as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }
        let temps = Dictionary(uniqueKeysWithValues: ModelBlend.members.map { ($0, series("temperature_2m", $0)) })
        let feels = Dictionary(uniqueKeysWithValues: ModelBlend.members.map { ($0, series("apparent_temperature", $0)) })
        let precip = Dictionary(uniqueKeysWithValues: ModelBlend.members.map { ($0, series("precipitation", $0)) })

        let nowEpoch = now.timeIntervalSince1970
        let observedTemperature = anchor?.temperature
        // Each model's temperature at the minute of the reading, read between the hours around it.
        let currentModelTemps: [WeatherModel: Double]? = anchor.map { a in
            Self.valuesAt(a.time.timeIntervalSince1970, times: times.map(\.doubleValue), series: temps)
        }

        var out = ModelTemperatures()
        for (i, t) in times.enumerated() {
            let lead = (t.doubleValue - nowEpoch) / 3600
            func at(_ s: [WeatherModel: [Double?]]) -> [WeatherModel: Double] {
                s.compactMapValues { i < $0.count ? $0[i] : nil }
            }
            let hourTemps = at(temps)
            guard let temp = ModelBlend.blend(hourTemps,
                                              leadHours: lead,
                                              observedTemperature: observedTemperature,
                                              currentModelTemps: currentModelTemps) else { continue }
            let values = Array(hourTemps.values)
            let hourPrecip = at(precip).filter { hourTemps[$0.key] != nil }
            let wet = hourPrecip.filter { $0.value >= ModelBlend.wetHourMm }.count
            out.hourly[t.intValue] = .init(temperature: temp,
                                           feelsLike: ModelBlend.blend(at(feels),
                                                                       leadHours: lead,
                                                                       observedTemperature: observedTemperature,
                                                                       currentModelTemps: currentModelTemps),
                                           low: values.min()!, high: values.max()!, count: values.count,
                                           wet: wet, freezing: values.filter { $0 <= 0 }.count,
                                           precipitation: hourPrecip)
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
        "pressure_msl",
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
                hour.pressure = h.pressure.value(at: i)
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

        // `past_days=1` adds yesterday. Everything else in the app starts at today 00:00, so
        // yesterday's hours are kept apart (with today's, unblended) and yesterday's row is dropped.
        let timeZoneIdentifier = r.timezone ?? TimeZone.current.identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let startOfToday = calendar.startOfDay(for: current.time)
        var recentHours: [HourlyForecast]? = nil
        if hourly.contains(where: { $0.time < startOfToday }) {
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            recentHours = hourly.filter { $0.time < startOfTomorrow }
            hourly = hourly.filter { $0.time >= startOfToday }
        }
        // Daily rows are dated at local midnight; the hour of slack covers odd time-zone data.
        daily = daily.filter { $0.date > startOfToday.addingTimeInterval(-3600) }

        var forecast = Forecast(
            location: Coordinate(latitude: r.latitude, longitude: r.longitude),
            timeZoneIdentifier: timeZoneIdentifier,
            current: current,
            hourly: hourly,
            daily: daily,
            source: "Open-Meteo",
            fetchedAt: fetchedAt,
            minutely: minutely
        )
        forecast.recentHours = recentHours
        return forecast.withDailyHeadlines()
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
        let pressure: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time, precipitation, rain, showers, snowfall, visibility
            case pressure = "pressure_msl"
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
                h.modelLow = t.low
                h.modelHigh = t.high
                h.modelCount = t.count
                h.modelsWet = t.wet
                h.modelsFreezing = t.freezing
                h.precipitationProbability = ModelBlend.hourlyChance(openMeteo: h.precipitationProbability,
                                                                     wet: t.wet, of: t.count)
            }
            return h
        }
        copy.daily = daily.enumerated().map { index, day in
            var d = day
            let hours = copy.hours(on: day).filter { temps.hourly[Int($0.time.timeIntervalSince1970)] != nil }
            if hours.count >= 20 {
                // Each model's total for the day, from the models that cover every hour of it.
                var totals: [WeatherModel: Double] = [:], counts: [WeatherModel: Int] = [:]
                for h in hours {
                    for (m, mm) in temps.hourly[Int(h.time.timeIntervalSince1970)]?.precipitation ?? [:] {
                        totals[m, default: 0] += mm
                        counts[m, default: 0] += 1
                    }
                }
                let full = totals.filter { counts[$0.key] == hours.count }
                d.precipitationProbability = ModelBlend.dailyChance(
                    openMeteo: d.precipitationProbability,
                    wet: full.values.filter { $0 >= ModelBlend.wetDayMm }.count,
                    of: full.count, dayIndex: index)
            }
            let spreads = hours.compactMap { h in h.modelHigh.flatMap { hi in h.modelLow.map { hi - $0 } } }
            if !spreads.isEmpty { d.modelSpread = spreads.reduce(0, +) / Double(spreads.count) }
            guard hours.count >= 18 else { return d }  // ensure blended daily high/low match the 8-model hourly curve
            d.high = hours.map(\.temperature).max()!
            d.low = hours.map(\.temperature).min()!
            let feels = hours.compactMap(\.feelsLike)
            if feels.count == hours.count {
                d.feelsLikeHigh = feels.max()
                d.feelsLikeLow = feels.min()
            }
            return d
        }
        // A day whose chance fell may no longer be headlined as rain.
        return copy.withDailyHeadlines()
    }
}

private extension Optional {
    /// Safe lookup into an optional array of optionals, as Open-Meteo returns them.
    func value<T>(at index: Int) -> T? where Wrapped == [T?] {
        guard let array = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
