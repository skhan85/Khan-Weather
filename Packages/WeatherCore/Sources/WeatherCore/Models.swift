import Foundation

/// A point on Earth. Rounded to 4 decimals (about 11 m) before it is sent to any provider.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Used when location access is denied or not yet available.
    public static let fallback = Coordinate(latitude: 43.6532, longitude: -79.3832) // Toronto

    var rounded: Coordinate {
        Coordinate(latitude: (latitude * 10_000).rounded() / 10_000,
                   longitude: (longitude * 10_000).rounded() / 10_000)
    }
}

/// Which formula the provider used for "feels like", so the UI can label it.
public enum FeelsLikeKind: String, Codable, Sendable {
    case apparent   // Open-Meteo, WeatherKit-style apparent temperature
    case humidex    // Environment Canada, summer
    case windChill  // Environment Canada, winter
}

public struct CurrentConditions: Equatable, Codable, Sendable {
    public var time: Date
    public var temperature: Double
    public var feelsLike: Double
    public var feelsLikeKind: FeelsLikeKind
    public var humidity: Double?
    public var windSpeed: Double?       // km/h
    public var windDirection: Double?   // degrees
    public var precipitation: Double?   // mm
    public var condition: WeatherCondition
    public var isDay: Bool
    /// Sea-level pressure, hPa.
    public var pressure: Double?
    public var windGusts: Double?       // km/h

    public init(time: Date, temperature: Double, feelsLike: Double, feelsLikeKind: FeelsLikeKind,
                humidity: Double? = nil, windSpeed: Double? = nil, windDirection: Double? = nil,
                precipitation: Double? = nil, condition: WeatherCondition, isDay: Bool,
                pressure: Double? = nil, windGusts: Double? = nil) {
        self.pressure = pressure
        self.windGusts = windGusts
        self.time = time
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.feelsLikeKind = feelsLikeKind
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.precipitation = precipitation
        self.condition = condition
        self.isDay = isDay
    }
}

public struct HourlyForecast: Equatable, Codable, Sendable, Identifiable {
    public var time: Date
    public var temperature: Double
    public var feelsLike: Double?
    public var precipitationProbability: Double?
    /// Precipitation in the hour, mm.
    public var precipitation: Double?
    public var condition: WeatherCondition
    /// False between sunset and sunrise, so clear hours show a moon instead of a sun.
    public var isDay: Bool
    // Detail fields, shown when the hour is tapped. All optional.
    public var humidity: Double?
    public var dewPoint: Double?
    /// km/h
    public var windSpeed: Double?
    /// km/h
    public var windGusts: Double?
    /// Degrees the wind comes from.
    public var windDirection: Double?
    public var uvIndex: Double?
    /// mm
    public var rain: Double?
    /// cm
    public var snowfall: Double?
    /// metres
    public var visibility: Double?
    /// Sea-level pressure, hPa.
    public var pressure: Double?
    // How the models in the blend see this hour (where the blend is used, see BlendRegion).
    /// Coldest and warmest model temperature, °C.
    public var modelLow: Double?
    public var modelHigh: Double?
    /// Models with a value, and how many of them have at least 0.2 mm or are at or below 0 °C.
    public var modelCount: Int?
    public var modelsWet: Int?
    public var modelsFreezing: Int?
    public var id: Date { time }

    /// What a precipitation chance for this hour would be.
    public var precipitationKind: PrecipitationKind {
        PrecipitationKind.guess(rain: rain, snow: snowfall, condition: condition,
                                low: temperature, high: temperature)
    }

    /// True when both rain and snow are expected in meaningful amounts this hour.
    public var isMixedPrecipitation: Bool {
        condition.isPrecipitation && (rain ?? 0) >= 0.2 && (snowfall ?? 0) >= 0.2
    }

    /// Makes this hour's rain and snow match `type`: pure rain/snow moves all water to one side;
    /// `.mixed` splits water between rain (mm) and snow (cm) according to `snowShare`. Freezing rain stays alone.
    mutating func setPrecipitationType(_ type: PrecipitationKind, snowShare: Double? = nil) {
        guard condition != .freezingRain, condition != .freezingDrizzle else { return }
        let water = max(precipitation ?? 0, (rain ?? 0) + (snowfall ?? 0) * 0.7)
        if type == .mixed {
            let share = min(0.8, max(0.2, snowShare ?? 0.5))
            condition = condition.converted(to: share >= 0.5 ? .snow : .rain)
            guard water > 0 else { return }
            snowfall = (water * share) / 0.7
            rain = water * (1 - share)
            return
        }
        condition = condition.converted(to: type)
        guard water > 0 else { return }
        if type == .snow { snowfall = water / 0.7; rain = 0 } else { rain = water; snowfall = 0 }
    }

    /// Upgrades dry sky conditions (e.g. Open-Meteo `overcast`) when ensemble precipitation is likely,
    /// so an hour with a 50%+ waterdrop/snowflake doesn't display a plain cloud icon.
    mutating func promoteLikelyPrecipitation(snowShare: Double? = nil) {
        guard !condition.isWetOrStorm else { return }
        let pop = precipitationProbability ?? 0
        let precip = max(precipitation ?? 0, (rain ?? 0) + (snowfall ?? 0) * 0.7)
        guard pop >= 50 || (precip >= 0.2 && pop >= 35) else { return }
        switch precipitationKind {
        case .snow: condition = .snow
        case .rain: condition = .rain
        case .mixed:
            let share = snowShare ?? (temperature <= 1.5 ? 0.5 : 0.0)
            condition = share >= 0.5 ? .snow : .rain
        }
    }

    public init(time: Date, temperature: Double, feelsLike: Double? = nil,
                precipitationProbability: Double? = nil, precipitation: Double? = nil,
                condition: WeatherCondition, isDay: Bool = true) {
        self.precipitation = precipitation
        self.time = time
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.precipitationProbability = precipitationProbability
        self.condition = condition
        self.isDay = isDay
    }
}

public struct DailyForecast: Equatable, Codable, Sendable, Identifiable {
    public var date: Date
    public var high: Double
    public var low: Double
    public var feelsLikeHigh: Double?
    public var feelsLikeLow: Double?
    public var precipitationProbability: Double?
    public var condition: WeatherCondition
    /// Total rain and showers for the day, in mm.
    public var rainSum: Double?
    /// Total snowfall for the day, in cm.
    public var snowfallSum: Double?
    /// "Rain then snow" and the like, when one word doesn't cover the day.
    public var summary: String?
    // Detail fields, shown when the day is tapped. All optional.
    public var sunrise: Date?
    public var sunset: Date?
    public var uvIndexMax: Double?
    /// km/h
    public var windSpeedMax: Double?
    /// km/h
    public var windGustsMax: Double?
    public var windDirectionDominant: Double?
    public var precipitationHours: Double?
    /// How far apart the blended models are over the day, on average, °C. nil without a blend.
    public var modelSpread: Double?
    /// Extra peak lift / half-trough drop carried so Google-blended days can keep multi-model timing spread.
    public var phaseHighLift: Double? = nil
    public var phaseLowDrop: Double? = nil
    public var id: Date { date }

    /// Sure when the models are within about 2°, unsure past about 4°.
    public var confidence: ForecastConfidence? {
        guard let modelSpread else { return nil }
        if modelSpread <= 2.5 { return .sure }
        if modelSpread <= 4.5 { return .fair }
        return .unsure
    }

    /// What the day's precipitation chance is a chance of.
    public var precipitationKind: PrecipitationKind {
        PrecipitationKind.guess(rain: rainSum, snow: snowfallSum, condition: condition, low: low, high: high)
    }

    /// True when the day brings both rain and snow.
    public var isMixedPrecipitation: Bool {
        condition.isPrecipitation && (((rainSum ?? 0) >= 0.2 && (snowfallSum ?? 0) >= 0.2) || summary != nil)
    }

    public init(date: Date, high: Double, low: Double, feelsLikeHigh: Double? = nil, feelsLikeLow: Double? = nil,
                precipitationProbability: Double? = nil, condition: WeatherCondition,
                rainSum: Double? = nil, snowfallSum: Double? = nil) {
        self.date = date
        self.high = high
        self.low = low
        self.feelsLikeHigh = feelsLikeHigh
        self.feelsLikeLow = feelsLikeLow
        self.precipitationProbability = precipitationProbability
        self.condition = condition
        self.rainSum = rainSum
        self.snowfallSum = snowfallSum
    }
}

/// Fifteen minutes of precipitation from the short-range forecast, used for "rain starting in 20 min".
public struct PrecipitationSlot: Equatable, Codable, Sendable {
    /// Start of the 15-minute period.
    public var time: Date
    /// Total precipitation in mm (water equivalent).
    public var precipitation: Double
    /// Rain in mm.
    public var rain: Double
    /// Snowfall in cm.
    public var snowfall: Double

    public init(time: Date, precipitation: Double, rain: Double = 0, snowfall: Double = 0) {
        self.time = time
        self.precipitation = precipitation
        self.rain = rain
        self.snowfall = snowfall
    }

    /// Below this a slot counts as dry; 0.1 mm per 15 min is about the lightest drizzle a gauge records.
    public static let wetThreshold = 0.1
    public var isWet: Bool { precipitation >= Self.wetThreshold || snowfall >= 0.1 }
}

public struct Forecast: Equatable, Codable, Sendable {
    public var location: Coordinate
    public var timeZoneIdentifier: String
    public var current: CurrentConditions
    public var hourly: [HourlyForecast]
    public var daily: [DailyForecast]
    public var source: String
    public var fetchedAt: Date
    /// Set when `current` comes from a real station observation rather than the forecast model.
    public var observation: Observation?
    /// The next couple of hours in 15-minute steps. Empty if the provider has none.
    public var minutely: [PrecipitationSlot]
    /// Set when the radar changed "now" (rain or snow falling here).
    public var radar: RadarNow?
    /// Where "now"'s sky (rain, snow, cloud) came from, for the caption: "radar over this spot",
    /// "Toronto Pearson, 25 km away" or "the forecast". nil means the forecast.
    public var skySource: String?
    /// The model's own hours from yesterday 00:00 through today, before any blending or station
    /// changes, for like-for-like "than yesterday" comparisons. nil when the provider has no past hours.
    public var recentHours: [HourlyForecast]?
    /// True when the daily highs and lows include `ModelBlend.highAllowance` / `lowAllowance` for
    /// the peak that falls between hours, so tonight's low gets the same allowance.
    public var extremesIncludePeak: Bool?

    public init(location: Coordinate, timeZoneIdentifier: String, current: CurrentConditions,
                hourly: [HourlyForecast], daily: [DailyForecast], source: String, fetchedAt: Date,
                observation: Observation? = nil, minutely: [PrecipitationSlot] = []) {
        self.location = location
        self.timeZoneIdentifier = timeZoneIdentifier
        self.current = current
        self.hourly = hourly
        self.daily = daily
        self.source = source
        self.fetchedAt = fetchedAt
        self.observation = observation
        self.minutely = minutely
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// The next `count` hours, starting with the hour that contains `date`.
    public func upcomingHours(from date: Date = Date(), count: Int = 24) -> [HourlyForecast] {
        Array(hourly.filter { $0.time.addingTimeInterval(3600) > date }.prefix(count))
    }

    /// The next hours, with the first one showing current conditions (the same numbers as the
    /// "now" card, which may come from a nearby station) instead of the forecast for that hour.
    /// Smoothing runs over at least 48 hours before trimming so every caller (19, 24, 30, 48h)
    /// sees identical numbers for overlapping hours.
    public func hoursStartingNow(from date: Date = Date(), count: Int = 24) -> [HourlyForecast] {
        var hours = upcomingHours(from: date, count: max(count, 48))
        guard !hours.isEmpty else { return hours }
        let c = current
        hours[0].temperature = c.temperature
        hours[0].feelsLike = c.feelsLike
        hours[0].condition = c.condition
        hours[0].isDay = c.isDay
        hours[0].humidity = c.humidity ?? hours[0].humidity
        hours[0].windSpeed = c.windSpeed ?? hours[0].windSpeed
        hours[0].windDirection = c.windDirection ?? hours[0].windDirection
        hours[0].windGusts = c.windGusts ?? hours[0].windGusts
        return Array(Self.withoutRoundingBlips(hours, keep: dayExtremeTimes(at: date)).prefix(count))
    }

    /// The hours of `day` as displayed on the Day detail screen: blip-smoothed with the same
    /// extreme protections as the main strip, and for Today, the active current hour matching "Now".
    public func displayHours(on day: DailyForecast, at date: Date = Date()) -> [HourlyForecast] {
        var hrs = hours(on: day)
        guard !hrs.isEmpty else { return hrs }
        if abs(current.time.timeIntervalSince(date)) < 3600,
           let idx = hrs.firstIndex(where: { $0.time <= date && $0.time.addingTimeInterval(3600) > date }) {
            let c = current
            hrs[idx].temperature = c.temperature
            hrs[idx].feelsLike = c.feelsLike
            hrs[idx].condition = c.condition
            hrs[idx].isDay = c.isDay
            hrs[idx].humidity = c.humidity ?? hrs[idx].humidity
            hrs[idx].windSpeed = c.windSpeed ?? hrs[idx].windSpeed
            hrs[idx].windDirection = c.windDirection ?? hrs[idx].windDirection
            hrs[idx].windGusts = c.windGusts ?? hrs[idx].windGusts
        }
        return Self.withoutRoundingBlips(hrs, keep: dayExtremeTimes(at: date))
    }

    /// The hour of each day's highest and lowest temperature, and of tonight's low. The hourly
    /// curve leaves these as they are, so it always shows the same high and low as the daily rows.
    func dayExtremeTimes(at date: Date = Date()) -> Set<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let byDay = Dictionary(grouping: hourly) { calendar.startOfDay(for: $0.time) }
        var out = Set<Date>()
        for hours in byDay.values {
            if let hi = hours.max(by: { $0.temperature < $1.temperature }) { out.insert(hi.time) }
            if let lo = hours.min(by: { $0.temperature < $1.temperature }) { out.insert(lo.time) }
        }
        if let coldestTonight = tonightHours(from: date).min(by: { $0.temperature < $1.temperature }) {
            out.insert(coldestTonight.time)
        }
        return out
    }

    /// A flat 6.4°, 6.5°, 6.4° reads "6°, 7°, 6°": one hour pops up or down only because it sits
    /// on the other side of a rounding line. When an hour's rounded value differs from two
    /// neighbours that agree, and the hour itself is within half a degree of them, it takes their
    /// average, which rounds the same as they do. Real one-hour changes are bigger and stay.
    /// Hours in `keep` (a day's high or low) are never changed.
    static func withoutRoundingBlips(_ hours: [HourlyForecast],
                                     unit: TemperatureUnit = UnitSettings.current.temperature,
                                     keep: Set<Date> = []) -> [HourlyForecast] {
        guard hours.count >= 3 else { return hours }
        var out = hours
        for i in 1..<(hours.count - 1) where !keep.contains(hours[i].time) {
            let a = unit.convert(hours[i - 1].temperature), b = unit.convert(hours[i].temperature)
            let c = unit.convert(hours[i + 1].temperature)
            guard a.rounded() == c.rounded(), b.rounded() != a.rounded(), abs(b - (a + c) / 2) < 0.6 else { continue }
            let fixed = (hours[i - 1].temperature + hours[i + 1].temperature) / 2
            let shift = fixed - hours[i].temperature
            out[i].temperature = fixed
            out[i].feelsLike = out[i].feelsLike.map { $0 + shift }
        }
        return out
    }

    /// The forecast hour that contains `date`, for values the "now" request doesn't carry
    /// (UV, visibility, dew point).
    public func hour(at date: Date = Date()) -> HourlyForecast? {
        upcomingHours(from: date, count: 1).first
    }

    /// Today's row of the daily forecast, in the place's time zone.
    public func day(at date: Date = Date()) -> DailyForecast? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return daily.first { calendar.isDate($0.date, inSameDayAs: date) } ?? daily.first
    }

    /// Forecast hours that make up tonight: from 6 PM (or `date`, if later) through 9 AM tomorrow.
    /// Before 6 AM "tonight" is the night we're in, so the window is `date` through 9 AM today.
    /// When `current` covers the active hour (`abs(current.time - date) < 3600`), prefers future
    /// hours (`> date`) so an already-started hour replaced by "Now" doesn't skew tonight's min.
    private func tonightHours(from date: Date) -> [HourlyForecast] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: date)
        let start: Date, end: Date
        if calendar.component(.hour, from: date) < 6 {
            guard let nineAM = calendar.date(byAdding: .hour, value: 9, to: startOfToday) else { return [] }
            start = date
            end = nineAM
        } else {
            guard let sixPM = calendar.date(byAdding: .hour, value: 18, to: startOfToday),
                  let nineAMTomorrow = calendar.date(byAdding: .hour, value: 33, to: startOfToday) else { return [] }
            start = max(date, sixPM)
            end = nineAMTomorrow
        }
        // From the hour that contains `start`, so 7:40 PM still counts the 7 PM hour when current is stale.
        let from = start.addingTimeInterval(-3599)
        if abs(current.time.timeIntervalSince(date)) < 3600 {
            let future = hourly.filter { $0.time > max(date, start.addingTimeInterval(-3599)) && $0.time <= end }
            if !future.isEmpty { return future }
        }
        return hourly.filter { $0.time >= from && $0.time <= end }
    }

    /// Lowest forecast temperature tonight: from 6 PM (or `date`, if later) through 9 AM tomorrow.
    /// Before 6 AM "tonight" is the night we're in, so the window is `date` through 9 AM today.
    public func tonightLow(from date: Date = Date()) -> Double? {
        tonightHours(from: date).map(\.temperature).min()
    }

    /// A saved forecast shown later (the network failed): "now" moves to the forecast hour for
    /// `date`, since the old station reading and radar no longer describe it. Within the hour it
    /// was made, the forecast is returned as it is.
    public func rolledForward(to date: Date = Date()) -> Forecast {
        guard date.timeIntervalSince(current.time) > 3600, let h = hour(at: date) else { return self }
        var copy = self
        copy.current = CurrentConditions(time: date, temperature: h.temperature, feelsLike: h.feelsLike ?? h.temperature,
                                         feelsLikeKind: .apparent, humidity: h.humidity, windSpeed: h.windSpeed,
                                         windDirection: h.windDirection, precipitation: h.precipitation,
                                         condition: h.condition, isDay: h.isDay, pressure: nil, windGusts: h.windGusts)
        copy.observation = nil
        copy.radar = nil
        copy.skySource = nil
        return copy
    }

    /// The daily rows as every screen and the widget show them: today's low is tonight's low
    /// (like The Weather Network), never above today's high. Use this instead of `daily` for
    /// anything displayed, so the list, the Now card, the day screen and the widget agree.
    public func displayDaily(at date: Date = Date()) -> [DailyForecast] {
        guard let todayIndex = todayIndex(at: date) else { return daily }
        var rows = daily
        if let tonight = tonightLow(from: date) {
            let allowance = extremesIncludePeak == true ? ModelBlend.lowAllowance : 0
            var low = tonight - allowance
            // Never show a daily low warmer than right now or today's remaining hours.
            if abs(current.time.timeIntervalSince(date)) < 7200 {
                low = min(low, current.temperature)
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
            let from = abs(current.time.timeIntervalSince(date)) < 3600 ? date.addingTimeInterval(1) : date.addingTimeInterval(-3599)
            if let remMin = hourly.filter({ $0.time >= from && $0.time <= endOfToday }).map(\.temperature).min() {
                low = min(low, remMin - allowance)
            }
            rows[todayIndex].low = min(low, rows[todayIndex].high)
        }
        return rows
    }

    /// Today's row as displayed (see `displayDaily`).
    public func displayDay(at date: Date = Date()) -> DailyForecast? {
        let rows = displayDaily(at: date)
        return todayIndex(at: date).map { rows[$0] } ?? rows.first
    }

    private func todayIndex(at date: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return daily.firstIndex { calendar.isDate($0.date, inSameDayAs: date) }
    }
}

public enum ForecastError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case missingData(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "The weather service returned HTTP \(code)."
        case .missingData(let field): return "The weather service response was missing \(field)."
        }
    }
}

/// Anything that can produce a forecast for a coordinate.
public protocol ForecastProvider: Sendable {
    var name: String { get }
    var attribution: String { get }
    func forecast(for coordinate: Coordinate) async throws -> Forecast
}

/// Rain, snow, or either, so a "40%" can say what it's a chance of.
public enum ForecastConfidence: String, Sendable {
    case sure, fair, unsure

    public var label: String {
        switch self {
        case .sure: return "Models agree"
        case .fair: return "Models mostly agree"
        case .unsure: return "Models disagree"
        }
    }
}

public enum PrecipitationKind: String, Codable, Sendable {
    case rain, snow, mixed

    /// SF Symbol shown next to the percentage.
    public var symbolName: String {
        switch self {
        case .rain: return "drop.fill"
        case .snow: return "snowflake"
        case .mixed: return "cloud.sleet.fill"
        }
    }

    /// "rain", "snow", "rain or snow".
    public var noun: String {
        switch self {
        case .rain: return "rain"
        case .snow: return "snow"
        case .mixed: return "rain or snow"
        }
    }

    /// Uses forecast amounts when there are any, then the condition, then temperature.
    static func guess(rain: Double?, snow: Double?, condition: WeatherCondition,
                      low: Double, high: Double) -> PrecipitationKind {
        let r = rain ?? 0, s = snow ?? 0
        if r > 0 && s > 0 { return .mixed }
        if s > 0 { return .snow }
        if r > 0 { return .rain }
        switch condition {
        case .snow, .snowGrains, .snowShowers: return .snow
        case .freezingRain, .freezingDrizzle: return .mixed
        case .rain, .rainShowers, .drizzle, .thunderstorm, .thunderstormHail: return .rain
        default: break
        }
        if high <= 1 { return .snow }
        if low >= 3 { return .rain }
        return .mixed
    }
}

public extension Forecast {
    /// The hours that fall on `day`'s date in the forecast's time zone.
    func hours(on day: DailyForecast) -> [HourlyForecast] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return hourly.filter { calendar.isDate($0.time, inSameDayAs: day.date) }
    }
}

public extension Forecast {
    /// Below this chance a day isn't headlined as rain or snow, even if the model has a few wet hours.
    static let headlineChance: Double = 35

    /// Open-Meteo's daily weather code is the worst hour of the day, so a brief overnight flurry
    /// makes a 13° day say "Snow". Re-pick each day's headline from its hours.
    func withDailyHeadlines() -> Forecast {
        var copy = self
        copy.daily = daily.map { day in
            var d = day
            d.summary = nil
            let hours = self.hours(on: day)
            guard d.condition.isPrecipitation || d.condition == .thunderstorm || d.condition == .thunderstormHail,
                  !hours.isEmpty else { return d }
            // A low chance only means a dry day when the models also expect little: 2 mm over
            // 7 hours is a wet day whatever the probability says.
            let wetHours = hours.filter { ($0.precipitation ?? 0) >= 0.1 }.count
            let total = (d.rainSum ?? 0) + (d.snowfallSum ?? 0) * 0.7
            let substantial = total >= 1 || wetHours >= 3
            if (d.precipitationProbability ?? 100) < Self.headlineChance, !substantial {
                d.condition = Self.dryHeadline(hours)
                return d
            }
            // Which kind falls when, from the wet hours.
            let wet = hours.filter { ($0.precipitation ?? 0) >= 0.1 || ($0.snowfall ?? 0) > 0 || ($0.rain ?? 0) > 0 }
            let kinds = wet.map { h -> PrecipitationKind in
                if (h.snowfall ?? 0) > 0 && (h.rain ?? 0) <= 0 { return .snow }
                if (h.rain ?? 0) > 0 && (h.snowfall ?? 0) <= 0 { return .rain }
                return h.temperature <= 1 ? .snow : .rain
            }
            guard let first = kinds.first, let last = kinds.last else { return d }
            let hasRain = kinds.contains(.rain), hasSnow = kinds.contains(.snow)
            if hasRain && hasSnow {
                d.summary = first == .rain && last == .snow ? "Rain then snow"
                    : first == .snow && last == .rain ? "Snow then rain" : "Rain and snow"
                let snowHours = kinds.filter { $0 == .snow }.count
                d.condition = snowHours * 2 > kinds.count ? .snow : .rain
            } else if hasRain, d.condition == .snow || d.condition == .snowShowers || d.condition == .snowGrains {
                d.condition = .rain
            } else if hasSnow, d.condition == .rain || d.condition == .rainShowers || d.condition == .drizzle {
                d.condition = .snow
            }
            return d
        }
        return copy
    }

    /// The most common sky among the day's daylight hours, ignoring the odd wet one.
    private static func dryHeadline(_ hours: [HourlyForecast]) -> WeatherCondition {
        let pool = hours.filter(\.isDay).isEmpty ? hours : hours.filter(\.isDay)
        var counts: [WeatherCondition: Int] = [:]
        for h in pool where !h.condition.isPrecipitation { counts[h.condition, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key ?? .overcast
    }
}

