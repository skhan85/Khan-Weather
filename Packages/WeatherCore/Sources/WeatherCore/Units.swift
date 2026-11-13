import Foundation

public enum TemperatureUnit: String, CaseIterable, Codable, Sendable {
    case celsius, fahrenheit

    public var label: String { self == .celsius ? "°C" : "°F" }

    /// Converts from °C.
    public func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

public enum WindUnit: String, CaseIterable, Codable, Sendable {
    case kmh, mph, ms, knots

    public var label: String {
        switch self {
        case .kmh: return "km/h"
        case .mph: return "mph"
        case .ms: return "m/s"
        case .knots: return "knots"
        }
    }

    /// Converts from km/h.
    public func convert(_ kmh: Double) -> Double {
        switch self {
        case .kmh: return kmh
        case .mph: return kmh / 1.609344
        case .ms: return kmh / 3.6
        case .knots: return kmh / 1.852
        }
    }
}

public enum PrecipitationUnit: String, CaseIterable, Codable, Sendable {
    /// Rain in mm, snow in cm.
    case metric
    /// Rain and snow in inches.
    case inches

    public var label: String { self == .metric ? "mm / cm" : "inches" }
}

/// The user's unit choices, stored in UserDefaults by the app's Settings screen.
public struct UnitSettings: Equatable, Sendable {
    public var temperature: TemperatureUnit
    public var wind: WindUnit
    public var precipitation: PrecipitationUnit

    public init(temperature: TemperatureUnit = .celsius, wind: WindUnit = .kmh,
                precipitation: PrecipitationUnit = .metric) {
        self.temperature = temperature
        self.wind = wind
        self.precipitation = precipitation
    }

    public static let temperatureKey = "unitTemperature"
    public static let windKey = "unitWind"
    public static let precipitationKey = "unitPrecipitation"

    public static func load(from defaults: UserDefaults = .standard) -> UnitSettings {
        UnitSettings(
            temperature: defaults.string(forKey: temperatureKey).flatMap(TemperatureUnit.init) ?? .celsius,
            wind: defaults.string(forKey: windKey).flatMap(WindUnit.init) ?? .kmh,
            precipitation: defaults.string(forKey: precipitationKey).flatMap(PrecipitationUnit.init) ?? .metric
        )
    }

    /// Read on every format call so a change in Settings shows up on the next redraw.
    public static var current: UnitSettings { load() }
}

public extension WeatherCondition {
    /// Rain, snow, drizzle and the like, but not thunderstorms.
    var isPrecipitation: Bool {
        switch self {
        case .drizzle, .freezingDrizzle, .rain, .freezingRain, .snow, .snowGrains, .rainShowers, .snowShowers:
            return true
        default:
            return false
        }
    }

    /// The model sometimes flags a stray flurry or sprinkle that barely registers. Two spots a
    /// kilometre apart can then show snow and cloud for the same hour. When the amount is a trace
    /// and the chance is low, show cloud instead. Needs a known amount; otherwise unchanged.
    func ignoringTrace(probability: Double?, amountMm: Double?) -> WeatherCondition {
        guard isPrecipitation, let amountMm, amountMm < 0.2, (probability ?? 0) < 20 else { return self }
        return .overcast
    }
}

public extension WeatherFormat {
    /// 8-point compass for the direction the wind comes from: "NW".
    static func compass(_ degrees: Double?) -> String? {
        guard let degrees else { return nil }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return names[i]
    }

    /// "Low", "Moderate", "High", "Very high", "Extreme" (WHO UV index bands).
    static func uvLevel(_ uv: Double?) -> String? {
        guard let uv else { return nil }
        let level: String
        switch uv {
        case ..<3: level = "Low"
        case ..<6: level = "Moderate"
        case ..<8: level = "High"
        case ..<11: level = "Very high"
        default: level = "Extreme"
        }
        return "\(Int(uv.rounded())) \(level)"
    }
}
