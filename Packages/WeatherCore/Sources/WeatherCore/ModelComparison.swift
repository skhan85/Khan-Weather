import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The same day from several weather models, side by side, so you can see how sure the forecast is.
public enum WeatherModel: String, CaseIterable, Sendable {
    case bestMatch = "best_match"
    case canada = "gem_seamless"
    case us = "gfs_seamless"
    case europe = "ecmwf_ifs025"
    case germany = "icon_seamless"

    public var name: String {
        switch self {
        case .bestMatch: return "Khan Weather (best match)"
        case .canada: return "Environment Canada (GEM)"
        case .us: return "NOAA (GFS)"
        case .europe: return "European (ECMWF)"
        case .germany: return "German (ICON)"
        }
    }
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

    public func days(at coordinate: Coordinate, forecastDays: Int = 10) async throws -> [ModelDay] {
        let c = coordinate.rounded
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(c.latitude)),
            URLQueryItem(name: "longitude", value: String(c.longitude)),
            URLQueryItem(name: "daily", value: Self.fields.joined(separator: ",")),
            URLQueryItem(name: "models", value: WeatherModel.allCases.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]
        return try Self.parse(try await fetch(parts.url!, loader: loader))
    }

    /// With several models, Open-Meteo suffixes each field: "temperature_2m_max_gem_seamless".
    static func parse(_ data: Data) throws -> [ModelDay] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let times = daily["time"] as? [NSNumber] else { throw ForecastError.missingData("daily") }
        func series(_ field: String, _ model: WeatherModel) -> [Double?] {
            let raw = (daily["\(field)_\(model.rawValue)"] ?? daily[field]) as? [Any] ?? []
            return raw.map { ($0 as? NSNumber)?.doubleValue }
        }
        var out: [ModelDay] = []
        for model in WeatherModel.allCases {
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
        return out
    }
}
