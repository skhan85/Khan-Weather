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
    /// Millibars, as UK forecasts say. Same number as hPa.
    case hPa, kPa, inHg, mb

    public var label: String { rawValue }

    /// Converts from hPa.
    public func convert(_ hPa: Double) -> Double {
        switch self {
        case .hPa, .mb: return hPa
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

/// Ready-made sets of units: what people in each country are used to seeing.
public enum UnitPreset: String, CaseIterable, Codable, Sendable {
    case canadian, us, uk

    public var label: String {
        switch self {
        case .canadian: return "Canadian"
        case .us: return "US"
        case .uk: return "UK"
        }
    }

    /// "°C · km/h · mm · km · kPa"
    public var detail: String {
        let s = settings
        let rain = s.precipitation == .inches ? "in" : "mm"
        let dist = s.distance == .km ? "km" : "mi"
        return [s.temperature.label, s.wind.label, rain, dist, s.pressure.label].joined(separator: " · ")
    }

    public var settings: UnitSettings {
        switch self {
        case .canadian: return UnitSettings(temperature: .celsius, wind: .kmh, precipitation: .metric, pressure: .kPa, distance: .km)
        case .us: return UnitSettings(temperature: .fahrenheit, wind: .mph, precipitation: .inches, pressure: .inHg, distance: .mi)
        case .uk: return UnitSettings(temperature: .celsius, wind: .mph, precipitation: .metric, pressure: .mb, distance: .mi)
        }
    }

    /// The preset for a region code: US (and the two other countries on US units) and the UK get
    /// their own; everywhere else gets the metric Canadian set.
    public static func forRegion(_ code: String?) -> UnitPreset {
        switch code?.uppercased() {
        case "US", "PR", "GU", "VI", "AS", "MP", "UM", "LR", "MM": return .us
        case "GB", "IM", "JE", "GG": return .uk
        default: return .canadian
        }
    }

    /// From the phone's region ("en_CA" -> Canadian). Parsed by hand so it works on Linux too.
    public static var deviceDefault: UnitPreset {
        let id = Locale.current.identifier.components(separatedBy: "@")[0]
        let parts = id.components(separatedBy: CharacterSet(charactersIn: "_-")).dropFirst()
        let region: String? = parts.first { $0.count == 2 && $0.allSatisfy { $0.isLetter } }
        return forRegion(region)
    }
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
    /// Set once the person has picked units (the first-launch question or Settings).
    public static let chosenKey = "unitsChosen"

    /// What the first-launch question suggests on a fresh install: the preset for the phone's region.
    /// (Until something is saved, `load` falls back to the Canadian set, so tests and command-line
    /// tools don't change with the machine's region.)
    public static var deviceDefault: UnitSettings { UnitPreset.deviceDefault.settings }

    /// Whether any unit has been saved, by Settings or the first-launch question.
    public static func hasSaved(in defaults: UserDefaults = .standard) -> Bool {
        [temperatureKey, windKey, precipitationKey, pressureKey, distanceKey].contains { defaults.string(forKey: $0) != nil }
    }

    /// The preset these units match, or nil for a mix ("Custom").
    public var preset: UnitPreset? { UnitPreset.allCases.first { $0.settings == self } }

    public static func load(from defaults: UserDefaults = .standard) -> UnitSettings {
        let d = UnitSettings()
        return UnitSettings(
            temperature: defaults.string(forKey: temperatureKey).flatMap(TemperatureUnit.init) ?? d.temperature,
            wind: defaults.string(forKey: windKey).flatMap(WindUnit.init) ?? d.wind,
            precipitation: defaults.string(forKey: precipitationKey).flatMap(PrecipitationUnit.init) ?? d.precipitation,
            pressure: defaults.string(forKey: pressureKey).flatMap(PressureUnit.init) ?? d.pressure,
            distance: defaults.string(forKey: distanceKey).flatMap(DistanceUnit.init) ?? d.distance
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(temperature.rawValue, forKey: Self.temperatureKey)
        defaults.set(wind.rawValue, forKey: Self.windKey)
        defaults.set(precipitation.rawValue, forKey: Self.precipitationKey)
        defaults.set(pressure.rawValue, forKey: Self.pressureKey)
        defaults.set(distance.rawValue, forKey: Self.distanceKey)
    }

    /// Read on every format call so a change in Settings shows up on the next redraw.
    public static var current: UnitSettings { load() }
}

public extension WeatherCondition {
    /// Rain, drizzle and showers, but not snow (which radar and home gauges can miss).
    var isRainLike: Bool {
        switch self {
        case .drizzle, .freezingDrizzle, .rain, .freezingRain, .rainShowers: return true
        default: return false
        }
    }

    /// Rain, snow, drizzle and the like, but not thunderstorms.
    var isPrecipitation: Bool {
        switch self {
        case .drizzle, .freezingDrizzle, .rain, .freezingRain, .snow, .snowGrains, .rainShowers, .snowShowers:
            return true
        default:
            return false
        }
    }

    var isWetOrStorm: Bool {
        isPrecipitation || self == .thunderstorm || self == .thunderstormHail
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
        case .hPa, .mb: return "\(Int(v.rounded())) \(unit.label)"
        case .kPa: return String(format: "%.1f kPa", v)
        case .inHg: return String(format: "%.2f inHg", v)
        }
    }

    /// Takes km: "13 km", "0.4 miles", one decimal under 10. Short distances in metres or feet:
    /// "400 m", "250 ft" (under 1 km, or under 0.1 mile).
    static func distance(_ km: Double?, unit: DistanceUnit = UnitSettings.current.distance) -> String? {
        guard let km else { return nil }
        if let short = shortDistance(km, unit: unit) { return short }
        let v = unit.convert(km)
        return v >= 10 || v == v.rounded() ? "\(Int(v.rounded())) \(unit.label)" : String(format: "%.1f %@", v, unit.label)
    }

    /// "1 m", "40 m", "400 m", "30 ft", "250 ft"; nil when the distance is long enough for km or miles.
    private static func shortDistance(_ km: Double, unit: DistanceUnit) -> String? {
        let small: Double
        let label: String
        switch unit {
        case .km:
            guard km < 1 else { return nil }
            small = km * 1000; label = "m"
        case .mi:
            guard km / 1.609344 < 0.1 else { return nil }
            small = km * 3280.839895; label = "ft"
        }
        let step: Double = small >= 100 ? 10 : 1
        return "\(Int(max(1, (small / step).rounded() * step))) \(label)"
    }

    /// A rough distance for "about … away": whole km or miles from 1 up, otherwise metres or
    /// feet to the nearest 100 (or 10 when very close). "3 km", "1.5 miles" only under 2 miles.
    static func roughDistance(_ km: Double, unit: DistanceUnit = UnitSettings.current.distance) -> String {
        let v = unit.convert(km)
        switch unit {
        case .km:
            if v >= 1 { return "\(Int(v.rounded())) km" }
            let m = km * 1000
            return "\(Int(max(1, m >= 100 ? (m / 100).rounded() * 100 : (m / 10).rounded() * 10))) m"
        case .mi:
            if v >= 2 { return "\(Int(v.rounded())) miles" }
            if v >= 0.1 {
                let r = (v * 10).rounded() / 10
                return r == 1 ? "1 mile" : r == r.rounded() ? "\(Int(r)) miles" : String(format: "%.1f miles", r)
            }
            let ft = km * 3280.839895
            return "\(Int(max(1, ft >= 100 ? (ft / 100).rounded() * 100 : (ft / 10).rounded() * 10))) ft"
        }
    }

    /// An hour's rain: "0.4 mm" or "0.02 in".
    static func rainAmount(_ mm: Double, unit: PrecipitationUnit = UnitSettings.current.precipitation) -> String {
        unit == .inches ? String(format: "%.2f in", mm / 25.4) : String(format: "%.1f mm", mm)
    }

    /// An hour's snow: "1.2 cm" or "0.47 in snow".
    static func snowAmount(_ cm: Double, unit: PrecipitationUnit = UnitSettings.current.precipitation) -> String {
        unit == .inches ? String(format: "%.2f in snow", cm / 2.54) : String(format: "%.1f cm", cm)
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
