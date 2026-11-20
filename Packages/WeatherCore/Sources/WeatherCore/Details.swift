import Foundation

// MARK: - Compared with yesterday

public extension Forecast {
    /// How much warmer (+) or colder (-) this hour is than the same time yesterday, °C.
    /// Both values come from the same unblended model run (`recentHours`), so a warm home station
    /// or the blend can't make today look different when the weather isn't.
    func changeSinceYesterday(at date: Date = Date()) -> Double? {
        guard let recent = recentHours, !recent.isEmpty else { return nil }
        guard let now = recent.last(where: { $0.time <= date && $0.time.addingTimeInterval(3600) > date }),
              let then = recent.first(where: { abs($0.time.timeIntervalSince(now.time) + 86_400) < 60 })
        else { return nil }
        return now.temperature - then.temperature
    }
}

/// "5° colder than yesterday at this time."
public enum YesterdayComparison {
    /// Rounded difference in the user's unit; under 2 degrees counts as "about the same".
    public static func degrees(_ changeC: Double, unit: TemperatureUnit = UnitSettings.current.temperature) -> Int {
        let d = unit == .fahrenheit ? changeC * 9 / 5 : changeC
        return Int(d.rounded())
    }

    public static func text(_ changeC: Double, unit: TemperatureUnit = UnitSettings.current.temperature) -> String {
        let d = degrees(changeC, unit: unit)
        if abs(d) < 2 { return "About the same as yesterday at this time" }
        return "\(abs(d))° \(d > 0 ? "warmer" : "colder") than yesterday at this time"
    }

    /// +1 warmer, -1 colder, 0 about the same.
    public static func trend(_ changeC: Double, unit: TemperatureUnit = UnitSettings.current.temperature) -> Int {
        let d = degrees(changeC, unit: unit)
        return abs(d) < 2 ? 0 : (d > 0 ? 1 : -1)
    }
}

// MARK: - Pressure trend

public enum PressureTrend: Equatable, Sendable {
    case rising(fast: Bool), falling(fast: Bool), steady

    /// SF Symbol for the tile.
    public var symbolName: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .steady: return "arrow.right"
        }
    }

    public var note: String {
        switch self {
        case .rising(let fast): return fast ? "Rising fast. Clearing, often windy." : "Rising. Weather usually settles."
        case .falling(let fast): return fast ? "Falling fast. A storm may be coming." : "Falling. Clouds or rain may be on the way."
        case .steady: return "Steady over the last 3 hours."
        }
    }

    /// From the change over 3 hours, hPa: under 1 is steady, 3 or more is fast.
    public static func from(change: Double) -> PressureTrend {
        if abs(change) < 1 { return .steady }
        let fast = abs(change) >= 3
        return change > 0 ? .rising(fast: fast) : .falling(fast: fast)
    }
}

public extension Forecast {
    /// The model's sea-level pressure now against 3 hours ago (both hourly values, not a station).
    func pressureTrend(at date: Date = Date()) -> PressureTrend? {
        guard let now = hour(at: date), let p = now.pressure else { return nil }
        let pool = hourly + (recentHours ?? [])
        let target = now.time.addingTimeInterval(-3 * 3600)
        guard let past = pool.first(where: { abs($0.time.timeIntervalSince(target)) < 60 && $0.pressure != nil })?.pressure
        else { return nil }
        return .from(change: p - past)
    }

    /// Rain (mm) and snow (cm) over the next `days` displayed days, starting today.
    func precipitationTotals(days count: Int = 7, at date: Date = Date()) -> (rainMm: Double, snowCm: Double)? {
        let rows = Array(displayDaily(at: date).prefix(count))
        guard rows.contains(where: { $0.rainSum != nil || $0.snowfallSum != nil }) else { return nil }
        return (rows.compactMap(\.rainSum).reduce(0, +), rows.compactMap(\.snowfallSum).reduce(0, +))
    }
}

// MARK: - Short explanations for the detail tiles

public enum DetailNotes {
    /// "Use sun protection until 2 PM." from today's remaining hours.
    public static func uv(hours: [HourlyForecast], hourText: (Date) -> String) -> String {
        let strong = hours.filter { ($0.uvIndex ?? 0) >= 3 }
        guard let first = strong.first, let last = strong.last else { return "Low for the rest of the day." }
        let end = last.time.addingTimeInterval(3600)
        if first.time == hours.first?.time { return "Use sun protection until \(hourText(end))." }
        return "Use sun protection from \(hourText(first.time)) to \(hourText(end))."
    }

    public static func visibility(km: Double) -> String {
        switch km {
        case ..<1: return "Fog. Drive slowly with low beams."
        case ..<5: return "Hazy or misty."
        case ..<10: return "A little haze."
        default: return "Clear view."
        }
    }

    /// "Dew point 4° right now. Feels dry." etc.
    public static func humidity(dewPoint: Double?) -> String {
        guard let dewPoint else { return "" }
        let comfort: String
        switch dewPoint {
        case ..<(-5): comfort = "Very dry air."
        case ..<10: comfort = "Comfortable."
        case ..<16: comfort = "A little humid."
        case ..<21: comfort = "Muggy."
        default: comfort = "Oppressive."
        }
        return "Dew point \(WeatherFormat.temperature(dewPoint)) right now. \(comfort)"
    }

    public static func gusts(gusts: Double, wind: Double?) -> String {
        let steady = wind.map { "Steady wind \(WeatherFormat.wind($0))." } ?? ""
        switch gusts {
        case 90...: return "Damaging gusts. Stay clear of trees. " + steady
        case 60..<90: return "Strong gusts. Secure loose things. " + steady
        case 40..<60: return "Gusty. Umbrellas may flip. " + steady
        default: return steady.isEmpty ? "Light gusts." : steady
        }
    }
}

// MARK: - Moon

/// The moon's phase from the mean synodic month. Good to about half a day, plenty for an icon.
public struct MoonPhase: Equatable, Sendable {
    public static let synodicMonth = 29.530588853
    /// A new moon: 2000-01-06 18:14 UTC.
    static let referenceNewMoon = Date(timeIntervalSince1970: 947_182_440)

    /// Days since the last new moon, 0 ..< 29.53.
    public let age: Double

    public init(date: Date = Date()) {
        let days = date.timeIntervalSince(Self.referenceNewMoon) / 86_400
        let a = days.truncatingRemainder(dividingBy: Self.synodicMonth)
        age = a < 0 ? a + Self.synodicMonth : a
    }

    /// Fraction of the disc lit, 0...1.
    public var illumination: Double { (1 - cos(2 * .pi * age / Self.synodicMonth)) / 2 }

    private var index: Int {
        // Quarter-phase names cover about a day either side; the in-between names fill the rest.
        let s = Self.synodicMonth
        switch age {
        case ..<1, (s - 1)...: return 0
        case ..<(s / 4 - 1): return 1
        case ..<(s / 4 + 1): return 2
        case ..<(s / 2 - 1): return 3
        case ..<(s / 2 + 1): return 4
        case ..<(3 * s / 4 - 1): return 5
        case ..<(3 * s / 4 + 1): return 6
        default: return 7
        }
    }

    public var name: String {
        ["New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
         "Full moon", "Waning gibbous", "Last quarter", "Waning crescent"][index]
    }

    /// SF Symbol (iOS 16+).
    public var symbolName: String {
        ["moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter", "moonphase.waxing.gibbous",
         "moonphase.full.moon", "moonphase.waning.gibbous", "moonphase.last.quarter", "moonphase.waning.crescent"][index]
    }

    /// When the moon is next full (if it's full now, the one after).
    public func nextFullMoon(after date: Date = Date()) -> Date {
        var days = Self.synodicMonth / 2 - age
        if days < 1 { days += Self.synodicMonth }
        return date.addingTimeInterval(days * 86_400)
    }
}
