import Foundation

/// Morning, afternoon, evening and overnight, for the "today in four parts" row.
public struct DayPart: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Sendable, CaseIterable {
        case overnight, morning, afternoon, evening

        public var label: String {
            switch self {
            case .overnight: return "Overnight"
            case .morning: return "Morning"
            case .afternoon: return "Afternoon"
            case .evening: return "Evening"
            }
        }

        /// First hour of the part: overnight 0–6, morning 6–12, afternoon 12–18, evening 18–24.
        var startHour: Int { rawValue * 6 }
        /// Daytime parts show their warmest hour, night parts their coldest.
        var showsHigh: Bool { self == .morning || self == .afternoon }
    }

    public var kind: Kind
    public var start: Date
    /// The warmest (morning, afternoon) or coldest (evening, overnight) hour's temperature, °C.
    public var temperature: Double
    public var feelsLike: Double?
    /// Highest chance of precipitation in the part.
    public var precipitationProbability: Double?
    public var precipitationKind: PrecipitationKind
    public var condition: WeatherCondition
    public var isDay: Bool
    public var id: Date { start }

    public init(kind: Kind, start: Date, temperature: Double, feelsLike: Double?, precipitationProbability: Double?,
                precipitationKind: PrecipitationKind, condition: WeatherCondition, isDay: Bool) {
        self.kind = kind
        self.start = start
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.precipitationProbability = precipitationProbability
        self.precipitationKind = precipitationKind
        self.condition = condition
        self.isDay = isDay
    }
}

public extension Forecast {
    /// The part of the day we're in and the three after it, built from the same hours as the
    /// hourly curve (`hoursStartingNow`), so every number matches the rest of the app.
    func dayParts(at date: Date = Date(), count: Int = 4) -> [DayPart] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hours = hoursStartingNow(from: date, count: 6 * (count + 1))
        guard !hours.isEmpty else { return [] }
        let startOfDay = calendar.startOfDay(for: date)
        let partIndex = calendar.component(.hour, from: date) / 6
        var out: [DayPart] = []
        for n in 0..<count {
            let index = partIndex + n
            guard let kind = DayPart.Kind(rawValue: index % 4),
                  let start = calendar.date(byAdding: .hour, value: index * 6, to: startOfDay),
                  let end = calendar.date(byAdding: .hour, value: 6, to: start) else { continue }
            // The current part counts from the hour we're in (shown as "now").
            let inPart = hours.filter { $0.time.addingTimeInterval(3600) > start && $0.time < end }
            guard !inPart.isEmpty else { continue }
            let pick = kind.showsHigh
                ? inPart.max { $0.temperature < $1.temperature }!
                : inPart.min { $0.temperature < $1.temperature }!
            let wettest = inPart.max { ($0.precipitationProbability ?? 0) < ($1.precipitationProbability ?? 0) }!
            let chance = inPart.compactMap(\.precipitationProbability).max()
            out.append(DayPart(kind: kind, start: start, temperature: pick.temperature, feelsLike: pick.feelsLike,
                               precipitationProbability: chance, precipitationKind: wettest.precipitationKind,
                               condition: Self.partCondition(inPart),
                               isDay: inPart.filter(\.isDay).count * 2 >= inPart.count))
        }
        return out
    }

    /// Rain or snow when it's likely in the part (or falls in at least two hours); otherwise the
    /// most common sky.
    static func partCondition(_ hours: [HourlyForecast]) -> WeatherCondition {
        let wet = hours.filter { $0.condition.isPrecipitation || $0.condition == .thunderstorm || $0.condition == .thunderstormHail }
        let maxChance = hours.compactMap(\.precipitationProbability).max()
        let likely = hours.contains { ($0.precipitationProbability ?? 0) >= headlineChance && $0.condition.isPrecipitation }
        if (maxChance ?? 100) >= 30 && !wet.isEmpty && (likely || wet.count >= 2) {
            var counts: [WeatherCondition: Int] = [:]
            for h in wet { counts[h.condition, default: 0] += 1 }
            return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }!.key
        }
        var counts: [WeatherCondition: Int] = [:]
        for h in hours where !h.condition.isPrecipitation && h.condition != .thunderstorm && h.condition != .thunderstormHail {
            counts[h.condition, default: 0] += 1
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key
            ?? hours[0].condition
    }
}
