import Foundation

/// "Rain starting in about 20 min" style summary of the next two hours.
public struct Nowcast: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case rain, snow, mixed

        var noun: String {
            switch self {
            case .rain: return "Rain"
            case .snow: return "Snow"
            case .mixed: return "Rain and snow"
            }
        }
    }

    public enum Change: Equatable, Sendable {
        case starting(minutes: Int)
        case stopping(minutes: Int)
        /// Wet now and for the whole window.
        case continuing
    }

    public var kind: Kind
    public var change: Change

    public var text: String {
        switch change {
        case .starting(let m): return "\(kind.noun) starting in about \(Self.duration(m))"
        case .stopping(let m): return "\(kind.noun) stopping in about \(Self.duration(m))"
        case .continuing: return "\(kind.noun) for at least the next 2 hours"
        }
    }

    /// Fits a small widget: "Rain in 25 min", "Snow ends in 1 hr".
    public var shortText: String {
        switch change {
        case .starting(let m): return "\(kind.noun) in \(Self.duration(m))"
        case .stopping(let m): return "\(kind.noun) ends in \(Self.duration(m))"
        case .continuing: return "\(kind.noun) next 2 hr"
        }
    }

    /// "20 min", "1 hr", "1 hr 15 min".
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) hr"
        default: return "\(h) hr \(m) min"
        }
    }

    static func kind(of slots: some Sequence<PrecipitationSlot>) -> Kind {
        var rain = 0.0, snow = 0.0
        for s in slots { rain += s.rain; snow += s.snowfall }
        if snow > 0 && rain >= PrecipitationSlot.wetThreshold { return .mixed }
        return snow > 0 ? .snow : .rain
    }

    /// Minutes from `now` to `date`, rounded to 5 and at least 5.
    static func minutes(from now: Date, to date: Date) -> Int {
        let raw = max(0, date.timeIntervalSince(now)) / 60
        return max(5, Int((raw / 5).rounded()) * 5)
    }
}

public extension Forecast {
    static let nowcastWindow: TimeInterval = 2 * 3600

    /// What precipitation is doing over the next two hours, or nil when it stays dry
    /// (or the 15-minute data is missing or stale).
    func nowcast(at now: Date = Date()) -> Nowcast? {
        let slots = minutely
            .filter { $0.time.addingTimeInterval(900) > now && $0.time < now.addingTimeInterval(Self.nowcastWindow) }
            .sorted { $0.time < $1.time }
        // The first slot must cover "now", otherwise the data is old and we'd be guessing.
        guard let first = slots.first, first.time <= now else { return nil }

        if first.isWet {
            let run = slots.prefix { $0.isWet }
            let kind = Nowcast.kind(of: run)
            if let dry = slots.first(where: { !$0.isWet }) {
                return Nowcast(kind: kind, change: .stopping(minutes: Nowcast.minutes(from: now, to: dry.time)))
            }
            return Nowcast(kind: kind, change: .continuing)
        }
        guard let start = slots.firstIndex(where: { $0.isWet }) else { return nil }
        let run = slots[start...].prefix { $0.isWet }
        return Nowcast(kind: Nowcast.kind(of: run),
                       change: .starting(minutes: Nowcast.minutes(from: now, to: slots[start].time)))
    }
}

public extension WeatherFormat {
    /// "3 mm", "2 cm", or "2 cm, 3 mm" for a day's totals; nil when there's less than 0.5 of either.
    static func precipitationTotals(rainMm: Double?, snowCm: Double?,
                                    unit: PrecipitationUnit = UnitSettings.current.precipitation) -> String? {
        if unit == .inches {
            // 0.1 in is about 2.5 mm of rain or 0.25 cm of snow; smaller totals round away.
            var parts: [String] = []
            if let snowCm, snowCm >= 0.5 { parts.append(inches(snowCm / 2.54) + " snow") }
            if let rainMm, rainMm >= 0.5 { parts.append(inches(rainMm / 25.4)) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        var parts: [String] = []
        if let snowCm, snowCm >= 0.5 { parts.append("\(max(1, Int(snowCm.rounded()))) cm") }
        if let rainMm, rainMm >= 0.5 { parts.append("\(max(1, Int(rainMm.rounded()))) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "0.1 in", "1.4 in"; at least 0.1.
    private static func inches(_ value: Double) -> String {
        String(format: "%.1f in", max(0.1, (value * 10).rounded() / 10))
    }
}

/// When a "rain starting soon" notification is worth sending.
public enum RainHeadsUp {
    /// iOS may wait up to an hour between background checks, so look a bit further ahead than "now".
    public static let lookAhead = 60
    /// One heads-up per wet spell: stay quiet this long after the last one.
    public static let quietPeriod: TimeInterval = 3 * 3600

    /// The nowcast to announce, or nil when it's dry, already wet, too far off, or we just told them.
    public static func shouldNotify(_ nowcast: Nowcast?, lastNotified: Date?, now: Date = Date()) -> Nowcast? {
        guard let nowcast, case .starting(let minutes) = nowcast.change, minutes <= lookAhead else { return nil }
        if let lastNotified, now.timeIntervalSince(lastNotified) < quietPeriod { return nil }
        return nowcast
    }

    /// "Rain starting in about 25 min" plus the time, e.g. "around 3:40 PM".
    public static func body(_ nowcast: Nowcast, at now: Date = Date(), timeZone: TimeZone) -> String {
        guard case .starting(let minutes) = nowcast.change else { return nowcast.text + "." }
        let start = now.addingTimeInterval(Double(minutes) * 60)
        let f = DateFormatter()
        f.timeZone = timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        return "\(nowcast.text), around \(f.string(from: start))."
    }
}
