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

    public init(kind: Kind, change: Change) {
        self.kind = kind
        self.change = change
    }

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
        switch PrecipitationSlot.kind(rain: rain, snowfall: snow) {
        case .rain: return .rain
        case .snow: return .snow
        case .mixed: return .mixed
        }
    }

    /// Minutes from `now` to `date`, rounded to 5 and at least 5.
    static func minutes(from now: Date, to date: Date) -> Int {
        let raw = max(0, date.timeIntervalSince(now)) / 60
        return max(5, Int((raw / 5).rounded()) * 5)
    }
}

public extension Forecast {
    static let nowcastWindow: TimeInterval = 2 * 3600

    /// The 15-minute slots of the next two hours that the nowcast reads, with live gauges and
    /// radar folded into the current slot. Empty when the data is missing or stale. The bars on
    /// the main screen draw these, so they always agree with the "Rain starting in" line.
    func nowcastSlots(at now: Date = Date()) -> [PrecipitationSlot] {
        var slots = minutely
            .filter { $0.time.addingTimeInterval(900) > now && $0.time < now.addingTimeInterval(Self.nowcastWindow) }
            .sorted { $0.time < $1.time }
        // The first slot must cover "now", otherwise the data is old and we'd be guessing.
        guard !slots.isEmpty, slots[0].time <= now else { return [] }

        // Bridge live PWS rain gauges and radar directly into the current 15-minute slot.
        // Home gauges aren't heated and miss snow, so they only overrule rain, above freezing
        // (the same rule as `dryIfGaugesSay`).
        if observation?.gaugesSayDry == true, radar?.isPrecipitating != true,
           current.temperature > 1, slots[0].snowfall == 0 {
            slots[0] = PrecipitationSlot(time: slots[0].time, precipitation: 0, rain: 0, snowfall: 0)
        } else if let radar, radar.isPrecipitating, !slots[0].isWet {
            // Only the radar says it's falling now; a gauge's last hour may be rain that has stopped.
            let hourlyRate = max(radar.rainMmPerHour, radar.snowCmPerHour)
            let slotAmount = max(PrecipitationSlot.wetThreshold, hourlyRate / 4.0)
            let rainPart = radar.isRaining
                ? max(radar.isSnowing ? PrecipitationSlot.wetThreshold : slotAmount, radar.rainMmPerHour / 4.0)
                : 0
            let snowPart = radar.isSnowing
                ? max(radar.isRaining ? PrecipitationSlot.wetThreshold : slotAmount, radar.snowCmPerHour / 4.0)
                : 0
            slots[0] = PrecipitationSlot(
                time: slots[0].time,
                precipitation: max(slotAmount, rainPart + snowPart),
                rain: rainPart,
                snowfall: snowPart
            )
        }

        // The Now card and this line must agree: when the card says it's raining or snowing now
        // (a nearby station's drizzle, or snow the radar can miss) but the 15-minute data is dry,
        // the current slot gets a light amount, so it reads "Rain stopping in..." rather than
        // "Rain starting in about 55 min" under "Light Rain".
        if !slots[0].isWet, current.condition.isPrecipitation {
            let snow = !current.condition.isRainLike
            // When more is due within the hour, the dry gap before it is filled too: drizzle now and
            // rain in 40 minutes reads "Rain for at least the next 2 hours", not "stopping in 15 min".
            let next = slots.firstIndex(where: \.isWet).flatMap { $0 <= Self.drizzleLeadSlots ? $0 : nil } ?? 1
            for i in 0..<next {
                slots[i] = PrecipitationSlot(time: slots[i].time, precipitation: PrecipitationSlot.wetThreshold,
                                             rain: snow ? 0 : PrecipitationSlot.wetThreshold,
                                             snowfall: snow ? PrecipitationSlot.wetThreshold / 0.7 : 0)
            }
        }

        // Each slot takes the same rain-or-snow call as its hour in the hourly list and on the Now
        // card (the models' vote, `RadarNow.typed`). Open-Meteo's 15-minute data puts a trace of snow
        // into most wet slots near 1°, which drew purple "Mixed" bars and "Rain and snow" in plain rain.
        return slots.map { s in
            guard s.isWet, s.rain > 0 || s.snowfall > 0, let models = modelPrecipitationKind(at: s.time) else { return s }
            let temp = hourly.last(where: { $0.time <= s.time }).map(\.temperature) ?? current.temperature
            let typed = RadarNow(rainMmPerHour: s.rain, snowCmPerHour: s.snowfall, time: s.time)
                .typed(byTemperature: temp, models: models)
            guard typed.snowCmPerHour == 0 || typed.rainMmPerHour == 0 else { return s }
            if typed.snowCmPerHour == 0 {
                return PrecipitationSlot(time: s.time, precipitation: s.precipitation, rain: max(s.rain, s.precipitation), snowfall: 0)
            }
            return PrecipitationSlot(time: s.time, precipitation: s.precipitation, rain: 0,
                                     snowfall: max(s.snowfall, s.precipitation / 0.7))
        }
    }

    /// The Now card follows the first 15 minutes of Next 2 hours when those are wet and the card
    /// isn't: 27 Nov, 8:54 am in Milton, the card said "Overcast" (the model's sky) under "Rain for
    /// at least the next 2 hours" while it drizzled. The radar over the spot showed nothing:
    /// drizzle falls from cloud too low for it to see.
    func agreeingNowWithNowcast(at now: Date = Date()) -> Forecast {
        guard !current.condition.isPrecipitation, current.condition != .thunderstorm,
              current.condition != .thunderstormHail else { return self }
        let slots = nowcastSlots(at: now)
        guard let first = slots.first, first.isWet else { return drizzlingRadarCantSee(slots: slots) }
        var copy = self
        let text: String
        switch first.kind {
        case .snow:
            copy.current.condition = .snow
            text = first.snowfall * 4 < 0.5 ? "Light snow" : first.snowfall * 4 < 1 ? "Moderate snow" : "Heavy snow"
        case .mixed:
            copy.current.condition = current.temperature <= 0 ? .freezingRain : .rain
            text = "Rain and snow"
        case .rain:
            let rate = max(first.rain, first.precipitation) * 4
            copy.current.condition = rate < 0.5 ? .drizzle : .rain
            text = rate < 0.5 ? "Drizzle" : rate < 2.5 ? "Light rain" : rate < 7.6 ? "Moderate rain" : "Heavy rain"
        }
        copy.observation?.conditionText = text
        return copy
    }

    /// Drizzle that neither the radar nor the 15-minute data shows. 27 Nov, 10:36 am in Milton:
    /// drizzling, but the card said "Overcast", "Sky from radar over this spot (dry)", and Next 2
    /// hours "Rain starting in about 40 min". Drizzle falls from cloud below the radar beam, and
    /// the models' 15-minute rain is often a little late. Either of these says it is drizzling:
    /// - an airport or station within 40 km reports drizzle, with damp air and cloud here;
    /// - very damp air under cloud, with rain due within the hour.
    func drizzlingRadarCantSee(slots: [PrecipitationSlot]) -> Forecast {
        guard [.overcast, .partlyCloudy, .fog].contains(current.condition),
              current.temperature > -3, current.temperature < 15,
              let rh = current.humidity, radar?.isPrecipitating != true else { return self }
        let nearby = observation?.nearbyDrizzleStation
        let rainSoon = slots.prefix(Self.drizzleLeadSlots).contains { $0.isWet && $0.kind == .rain }
        let source: String
        // Hamilton and Pearson are 25-35 km from Milton, so their drizzle alone isn't proof: it also
        // needs damp air and cloud cover here.
        if let nearby, rh >= Self.drizzleHumidity, current.condition != .partlyCloudy {
            let km = observation?.nearbyDrizzleKm.map { ", \(WeatherFormat.roughDistance($0)) away" } ?? ""
            source = "drizzle reported at \(nearby)\(km) (radar can't see drizzle)"
        } else if let wet = observation?.nearbyWetStations, wet.count >= Self.widespreadWetReports,
                  current.temperature > 1, rh >= Self.damperDrizzleHumidity, current.condition != .partlyCloudy {
            source = "light rain reported at \(wet.prefix(2).joined(separator: " and ")) (radar can't see it here)"
        } else if rainSoon, rh >= Self.damperDrizzleHumidity, current.condition != .partlyCloudy {
            source = "damp air with rain due within the hour (radar can't see drizzle)"
        } else if let share = modelWetShareNow, share >= Self.modelsWetDrizzleShare,
                  current.temperature > 1, rh >= Self.damperDrizzleHumidity, current.condition != .partlyCloudy {
            source = "most forecast models have light rain falling now (radar can't see drizzle)"
        } else {
            return self
        }
        var copy = self
        let freezing = current.temperature <= 0
        copy.current.condition = freezing ? .freezingDrizzle : .drizzle
        copy.observation?.conditionText = freezing ? "Freezing drizzle" : "Drizzle"
        copy.skySource = source
        return copy
    }

    /// Share of the blend's models (at least 3) with measurable rain (0.2 mm) in the hour holding now.
    var modelWetShareNow: Double? {
        guard let h = hourly.last(where: { $0.time <= current.time }),
              current.time.timeIntervalSince(h.time) < 3600,
              let n = h.modelCount, n >= 3, let w = h.modelsWet else { return nil }
        return Double(w) / Double(n)
    }
    /// Stations or airports within 40 km reporting rain or drizzle that make it "widespread".
    static let widespreadWetReports = 2
    /// Share of models wet now that, in damp air under cloud, says it's drizzling.
    static let modelsWetDrizzleShare = 0.5

    /// Rain this many 15-minute slots away (an hour) counts as "due" for drizzle.
    static let drizzleLeadSlots = 4
    /// Without a nearby drizzle report, the air must be at least this damp (%).
    static let damperDrizzleHumidity: Double = 90

    /// What precipitation is doing over the next two hours, or nil when it stays dry
    /// (or the 15-minute data is missing or stale).
    func nowcast(at now: Date = Date()) -> Nowcast? {
        let slots = nowcastSlots(at: now)
        guard !slots.isEmpty else { return nil }
        let first = slots[0]

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

    /// The first hour, between `from` and `within` hours ahead, when rain or snow is forecast and most
    /// models agree (at least 60 %, or no model counts to go on), as long as it isn't wet now.
    /// Lets the app schedule a heads-up ahead of time, since iOS may not wake it again before then.
    public static func upcomingWetHour(_ hourly: [HourlyForecast], now: Date = Date(),
                                       from: TimeInterval = 0, within hours: Int = 6) -> (time: Date, snow: Bool)? {
        func wet(_ h: HourlyForecast) -> Bool {
            let amount = (h.precipitation ?? 0) >= 0.3 || (h.rain ?? 0) >= 0.3 || (h.snowfall ?? 0) >= 0.3
            guard amount else { return false }
            if let n = h.modelCount, n > 0, let w = h.modelsWet { return Double(w) / Double(n) >= 0.6 }
            return (h.precipitationProbability ?? 100) >= 60
        }
        let sorted = hourly.sorted { $0.time < $1.time }
        // Already wet this hour: nothing is "starting".
        if let current = sorted.last(where: { $0.time <= now }), current.time.addingTimeInterval(3600) > now, wet(current) {
            return nil
        }
        let end = now.addingTimeInterval(Double(hours) * 3600)
        guard let h = sorted.first(where: { $0.time > now.addingTimeInterval(from) && $0.time <= end && wet($0) }) else { return nil }
        return (h.time, (h.snowfall ?? 0) > 0 && (h.rain ?? 0) < 0.3)
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
