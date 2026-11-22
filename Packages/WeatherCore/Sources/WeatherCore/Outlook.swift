import Foundation

/// One plain sentence about what's coming, shown on the Now card, e.g.
/// "Warming to a high of 15° by 1 pm." or "Cooling to 1° by 11 pm."
public enum Outlook {
    /// Hours the warm-up or cool-down is followed for, so a 4 am "warming" sentence reaches
    /// the afternoon high instead of stopping a few hours in.
    static let trendHours = 18
    /// Hours looked at for rain, a change of sky, or "steady".
    static let nearHours = 6

    /// Whole degrees in the user's unit, exactly as the screen shows them.
    private static func shown(_ celsius: Double) -> Int {
        Int(UnitSettings.current.temperature.convert(celsius).rounded())
    }

    private static func isCloudOnly(_ c: WeatherCondition) -> Bool {
        [.mainlyClear, .partlyCloudy, .overcast].contains(c)
    }

    /// The end of a warm-up (`rising`) or cool-down starting now: the warmest (coldest) hour
    /// before the temperature turns back by 2° or more. Uses the hours exactly as the hourly
    /// curve shows them.
    static func turningPoint(now: Int, later: [HourlyForecast], rising: Bool) -> HourlyForecast? {
        var best: HourlyForecast?
        var bestShown = now
        for hour in later.prefix(trendHours) {
            let t = shown(hour.temperature)
            if rising ? t > bestShown : t < bestShown {
                best = hour
                bestShown = t
            } else if rising ? t <= bestShown - 2 : t >= bestShown + 2 {
                break
            }
        }
        return best
    }

    /// Built from the same numbers as the Now card, the hourly curve and today's high/low,
    /// so they never disagree. `hourText` formats an hour like "1 pm" in the place's time zone.
    public static func text(_ forecast: Forecast, at date: Date = Date(),
                            hourText: (Date) -> String) -> String? {
        if let nowcast = forecast.nowcast(at: date) { return nowcast.text }
        let later = Array(forecast.hoursStartingNow(from: date, count: trendHours + 1).dropFirst())
        let near = Array(later.prefix(nearHours))
        guard near.count >= 3, let last = near.last else { return nil }
        let now = forecast.current
        // Rain or snow coming up is the most useful thing to say.
        if let wet = near.first(where: { ($0.precipitationProbability ?? 0) >= 50 }) {
            return "\(wet.precipitationKind.noun.capitalized) likely around \(hourText(wet.time))."
        }
        let nowShown = shown(now.temperature)
        // Evening and night: tonight's low matters more than tomorrow afternoon's high.
        if let night = overnightLow(forecast, at: date, nowShown: nowShown, hourText: hourText) {
            return night
        }
        let peak = turningPoint(now: nowShown, later: later, rising: true)
        let trough = turningPoint(now: nowShown, later: later, rising: false)
        let warmDelta = peak.map { shown($0.temperature) - nowShown } ?? 0
        let coolDelta = trough.map { nowShown - shown($0.temperature) } ?? 0
        if max(warmDelta, coolDelta) >= 2, let target = warmDelta >= coolDelta ? peak : trough {
            let warming = warmDelta >= coolDelta
            // Name it the high (low) only when it's the same number as today's high (tonight's
            // low) on the Now card, and it falls today (tonight).
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = forecast.timeZone
            let day = forecast.displayDay(at: date)
            let dayValue = warming ? day?.high : day?.low
            let isToday = warming ? calendar.isDate(target.time, inSameDayAs: date)
                                  : target.time <= tonightEnd(date, calendar)
            let label = (dayValue.map(shown) == shown(target.temperature) && isToday)
                ? (warming ? "a high of " : "a low of ") : ""
            return "\(warming ? "Warming" : "Cooling") to \(label)\(WeatherFormat.temperature(target.temperature)) by \(hourText(target.time))."
        }
        if last.condition != now.condition && !(isCloudOnly(last.condition) && isCloudOnly(now.condition)) {
            return "\(last.condition.description) by \(hourText(last.time))."
        }
        // Steady: quote the temperature the coming hours mostly show.
        let counts = Dictionary(grouping: near, by: { shown($0.temperature) }).mapValues(\.count)
        let typical = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? nowShown
        let typicalHour = near.first(where: { shown($0.temperature) == typical }) ?? last
        return "Steady around \(WeatherFormat.temperature(typicalHour.temperature)) for the next few hours."
    }

    /// From 4 pm until 4 am, while it's still getting colder: "Cooling to a low of 3° by 6 am.",
    /// with the same low as the Now card's high/low chip, at the coldest hour on the hourly curve.
    static let eveningStartHour = 16
    static let nightEndHour = 4

    private static func overnightLow(_ forecast: Forecast, at date: Date, nowShown: Int,
                                      hourText: (Date) -> String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let hour = calendar.component(.hour, from: date)
        guard hour >= eveningStartHour || hour < nightEndHour,
              forecast.tonightLow(from: date) != nil,
              let low = forecast.displayDay(at: date)?.low, shown(low) < nowShown else { return nil }
        let end = tonightEnd(date, calendar)
        let tonight = forecast.hoursStartingNow(from: date, count: 24).filter { $0.time > date && $0.time <= end }
        guard let coldest = tonight.min(by: { $0.temperature < $1.temperature }) else { return nil }
        return "Cooling to a low of \(WeatherFormat.temperature(low)) by \(hourText(coldest.time))."
    }

    /// 9 am tomorrow (or today, before 6 am): the end of "tonight", matching `tonightLow`.
    private static func tonightEnd(_ date: Date, _ calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let hours = calendar.component(.hour, from: date) < 6 ? 9 : 33
        return calendar.date(byAdding: .hour, value: hours, to: start) ?? date
    }
}
