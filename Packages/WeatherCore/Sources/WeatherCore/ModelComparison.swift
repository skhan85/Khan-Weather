import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The same day from several weather models, side by side, so you can see how sure the forecast is.
public enum WeatherModel: String, CaseIterable, Sendable {
    /// Khan Weather's own weighted average (ModelBlend); worked out here, not asked of Open-Meteo.
    case blend = "khan_blend"
    case bestMatch = "best_match"
    case canada = "gem_seamless"
    case canadaHighRes = "gem_hrdps_continental"
    case us = "gfs_seamless"
    case usHighRes = "gfs_hrrr"
    case europe = "ecmwf_ifs025"
    case uk = "ukmo_seamless"
    case germany = "icon_seamless"
    case europeAI = "ecmwf_aifs025_single"

    public var name: String {
        switch self {
        case .blend: return "Khan Weather blend"
        case .bestMatch: return "Open-Meteo best match"
        case .canada: return "Environment Canada (GEM)"
        case .canadaHighRes: return "Environment Canada high-res (HRDPS)"
        case .us: return "NOAA (GFS)"
        case .usHighRes: return "NOAA high-res (HRRR)"
        case .europe: return "European (ECMWF)"
        case .uk: return "UK Met Office"
        case .germany: return "German (ICON)"
        case .europeAI: return "European AI (AIFS)"
        }
    }

    /// The model Khan Weather's own temperatures come from at this spot.
    public static func usedForTemperatures(at coordinate: Coordinate) -> WeatherModel {
        OpenMeteoProvider.usesBlend(coordinate) ? .blend : .bestMatch
    }

    /// The models asked of Open-Meteo for the comparison.
    public static let requested: [WeatherModel] = allCases.filter { $0 != .blend }
}

public struct ModelDay: Equatable, Sendable, Identifiable {
    public var model: WeatherModel
    public var date: Date
    public var high: Double?
    public var low: Double?
    public var condition: WeatherCondition
    public var rainMm: Double?
    public var snowCm: Double?
    public var id: String { "\(model.rawValue)-\(date.timeIntervalSince1970)" }
}

public struct ModelComparisonProvider: Sendable {
    private let loader: HTTPLoader
    public init(loader: @escaping HTTPLoader = defaultLoader) { self.loader = loader }

    static let fields = ["weather_code", "temperature_2m_max", "temperature_2m_min", "rain_sum", "showers_sum", "snowfall_sum"]

    /// Models that have been on the comparison from the start, used again if a newer one is refused.
    static let core: [WeatherModel] = [.bestMatch, .canada, .us, .europe, .germany]

    public func days(at coordinate: Coordinate, forecastDays: Int = 10) async throws -> [ModelDay] {
        do {
            return try await days(at: coordinate, models: WeatherModel.requested, forecastDays: forecastDays)
        } catch {
            return try await days(at: coordinate, models: Self.core, forecastDays: forecastDays)
        }
    }

    func days(at coordinate: Coordinate, models: [WeatherModel], forecastDays: Int) async throws -> [ModelDay] {
        let c = coordinate.rounded
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(c.latitude)),
            URLQueryItem(name: "longitude", value: String(c.longitude)),
            URLQueryItem(name: "daily", value: Self.fields.joined(separator: ",")),
            URLQueryItem(name: "models", value: models.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]
        return try Self.parse(try await fetch(parts.url!, loader: loader), models: models,
                              region: BlendRegion.at(coordinate))
    }

    /// With several models, Open-Meteo suffixes each field: "temperature_2m_max_gem_seamless".
    static func parse(_ data: Data, models: [WeatherModel] = WeatherModel.requested,
                      region: BlendRegion = .home) throws -> [ModelDay] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let times = daily["time"] as? [NSNumber] else { throw ForecastError.missingData("daily") }
        func series(_ field: String, _ model: WeatherModel) -> [Double?] {
            let raw = (daily["\(field)_\(model.rawValue)"] ?? daily[field]) as? [Any] ?? []
            return raw.map { ($0 as? NSNumber)?.doubleValue }
        }
        var out: [ModelDay] = []
        for model in models {
            let hi = series("temperature_2m_max", model), lo = series("temperature_2m_min", model)
            let code = series("weather_code", model), rain = series("rain_sum", model)
            let showers = series("showers_sum", model), snow = series("snowfall_sum", model)
            for (i, t) in times.enumerated() {
                func at(_ a: [Double?]) -> Double? { i < a.count ? a[i] : nil }
                guard at(hi) != nil || at(lo) != nil else { continue }   // model doesn't reach this far
                out.append(ModelDay(model: model, date: Date(timeIntervalSince1970: t.doubleValue),
                                    high: at(hi), low: at(lo),
                                    condition: WeatherCondition(wmoCode: at(code).map { Int($0) }),
                                    rainMm: OpenMeteoProvider.sum(at(rain), at(showers)), snowCm: at(snow)))
            }
        }
        return out + blendRows(out, region: region)
    }

    /// The row for the model Khan Weather uses shows the app's own high and low for the day
    /// (the 10-day list, the Now card and the widget), not a blend of each model's daily max/min.
    /// Models peak at different hours, so averaging their highs runs warmer than the high of the
    /// averaged hourly curve the app shows (16° against 15°), and today's low is tonight's low.
    /// `appDays` are the app's displayed rows (`Forecast.displayDaily`); days it doesn't have keep
    /// the computed blend.
    public static func showingApp(_ rows: [ModelDay], appDays: [DailyForecast], used: WeatherModel,
                                  timeZone: TimeZone) -> [ModelDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return rows.map { row in
            guard row.model == used,
                  let day = appDays.first(where: { calendar.isDate($0.date, inSameDayAs: row.date) }) else { return row }
            var r = row
            r.high = day.high
            r.low = day.low
            return r
        }
    }

    /// One "Khan Weather blend" row per day, weighted the same way as the app's temperatures.
    static func blendRows(_ days: [ModelDay], region: BlendRegion = .home) -> [ModelDay] {
        let dates = Array(Set(days.map(\.date))).sorted()
        return dates.enumerated().compactMap { index, date in
            let sameDay = days.filter { $0.date == date && ModelBlend.members.contains($0.model) }
            let lead = Double(index) * 24 + 12
            func blend(_ value: (ModelDay) -> Double?) -> Double? {
                ModelBlend.blend(Dictionary(sameDay.compactMap { d in value(d).map { (d.model, $0) } },
                                            uniquingKeysWith: { a, _ in a }), leadHours: lead, region: region)
            }
            guard let high = blend(\.high), let low = blend(\.low) else { return nil }
            let condition = days.first { $0.date == date && $0.model == .bestMatch }?.condition
                ?? sameDay.first?.condition ?? .unknown
            return ModelDay(model: .blend, date: date, high: high, low: low, condition: condition,
                            rainMm: blend(\.rainMm), snowCm: blend(\.snowCm))
        }
    }
}
