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

public enum PressureUnit: String, CaseIterable, Codable, Sendable {
    case hPa, kPa, inHg

    public var label: String { rawValue }

    /// Converts from hPa.
    public func convert(_ hPa: Double) -> Double {
        switch self {
        case .hPa: return hPa
        case .kPa: return hPa / 10
        case .inHg: return hPa * 0.0295299830714
        }
    }
}

public enum DistanceUnit: String, CaseIterable, Codable, Sendable {
    case km, mi

    public var label: String { self == .km ? "km" : "miles" }

    /// Converts from km.
    public func convert(_ km: Double) -> Double { self == .km ? km : km / 1.609344 }
}

/// The user's unit choices, stored in UserDefaults by the app's Settings screen.
public struct UnitSettings: Equatable, Sendable {
    public var temperature: TemperatureUnit
    public var wind: WindUnit
    public var precipitation: PrecipitationUnit
    public var pressure: PressureUnit
    public var distance: DistanceUnit

    public init(temperature: TemperatureUnit = .celsius, wind: WindUnit = .kmh,
                precipitation: PrecipitationUnit = .metric, pressure: PressureUnit = .kPa,
                distance: DistanceUnit = .km) {
        self.temperature = temperature
        self.wind = wind
        self.precipitation = precipitation
        self.pressure = pressure
        self.distance = distance
    }

    public static let temperatureKey = "unitTemperature"
    public static let windKey = "unitWind"
    public static let precipitationKey = "unitPrecipitation"
    public static let pressureKey = "unitPressure"
    public static let distanceKey = "unitDistance"

    public static func load(from defaults: UserDefaults = .standard) -> UnitSettings {
        UnitSettings(
            temperature: defaults.string(forKey: temperatureKey).flatMap(TemperatureUnit.init) ?? .celsius,
            wind: defaults.string(forKey: windKey).flatMap(WindUnit.init) ?? .kmh,
            precipitation: defaults.string(forKey: precipitationKey).flatMap(PrecipitationUnit.init) ?? .metric,
            pressure: defaults.string(forKey: pressureKey).flatMap(PressureUnit.init) ?? .kPa,
            distance: defaults.string(forKey: distanceKey).flatMap(DistanceUnit.init) ?? .km
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

    /// Takes hPa: "101.3 kPa", "1013 hPa", "29.92 inHg".
    static func pressure(_ hPa: Double?, unit: PressureUnit = UnitSettings.current.pressure) -> String? {
        guard let hPa else { return nil }
        let v = unit.convert(hPa)
        switch unit {
        case .hPa: return "\(Int(v.rounded())) hPa"
        case .kPa: return String(format: "%.1f kPa", v)
        case .inHg: return String(format: "%.2f inHg", v)
        }
    }

    /// Takes km: "13 km", "0.4 miles". One decimal under 10.
    static func distance(_ km: Double?, unit: DistanceUnit = UnitSettings.current.distance) -> String? {
        guard let km else { return nil }
        let v = unit.convert(km)
        return v >= 10 || v == v.rounded() ? "\(Int(v.rounded())) \(unit.label)" : String(format: "%.1f %@", v, unit.label)
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
