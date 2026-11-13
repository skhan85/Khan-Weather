import Foundation

/// Provider-neutral sky/precipitation state.
public enum WeatherCondition: String, Codable, Sendable, CaseIterable {
    case clear, mainlyClear, partlyCloudy, overcast, fog
    case drizzle, freezingDrizzle, rain, freezingRain
    case snow, snowGrains, rainShowers, snowShowers
    case thunderstorm, thunderstormHail
    case unknown

    /// WMO weather interpretation codes, as used by Open-Meteo.
    public init(wmoCode: Int?) {
        switch wmoCode {
        case 0: self = .clear
        case 1: self = .mainlyClear
        case 2: self = .partlyCloudy
        case 3: self = .overcast
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57: self = .freezingDrizzle
        case 61, 63, 65: self = .rain
        case 66, 67: self = .freezingRain
        case 71, 73, 75: self = .snow
        case 77: self = .snowGrains
        case 80, 81, 82: self = .rainShowers
        case 85, 86: self = .snowShowers
        case 95: self = .thunderstorm
        case 96, 99: self = .thunderstormHail
        default: self = .unknown
        }
    }

    public var description: String {
        switch self {
        case .clear: return "Clear"
        case .mainlyClear: return "Mainly clear"
        case .partlyCloudy: return "Partly cloudy"
        case .overcast: return "Overcast"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .freezingDrizzle: return "Freezing drizzle"
        case .rain: return "Rain"
        case .freezingRain: return "Freezing rain"
        case .snow: return "Snow"
        case .snowGrains: return "Snow grains"
        case .rainShowers: return "Rain showers"
        case .snowShowers: return "Snow showers"
        case .thunderstorm: return "Thunderstorm"
        case .thunderstormHail: return "Thunderstorm with hail"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol name for this condition.
    public func symbolName(isDay: Bool = true) -> String {
        switch self {
        case .clear: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mainlyClear, .partlyCloudy: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: return "cloud.sleet.fill"
        case .rain: return "cloud.rain.fill"
        case .snow, .snowGrains, .snowShowers: return "cloud.snow.fill"
        case .rainShowers: return "cloud.heavyrain.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .thunderstormHail: return "cloud.hail.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

public enum WeatherFormat {
    /// "21°" style, rounded to whole degrees.
    /// Takes °C and shows it in the user's unit.
    public static func temperature(_ value: Double?) -> String {
        temperature(value, unit: UnitSettings.current.temperature)
    }

    public static func temperature(_ value: Double?, unit: TemperatureUnit) -> String {
        guard let value else { return "--" }
        let whole = Int(unit.convert(value).rounded())
        return "\(whole == 0 ? 0 : whole)°" // avoid "-0°"
    }

    /// Takes km/h: "12 km/h", "7 mph".
    public static func wind(_ kmh: Double?, unit: WindUnit = UnitSettings.current.wind) -> String {
        guard let kmh else { return "--" }
        return "\(Int(unit.convert(kmh).rounded())) \(unit.label)"
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    public static func feelsLikeLabel(_ kind: FeelsLikeKind) -> String {
        switch kind {
        case .apparent: return "Feels like"
        case .humidex: return "Humidex"
        case .windChill: return "Wind chill"
        }
    }
}
