import Foundation

/// One plain sentence over the daily list: which days bring rain or snow, how warm it peaks, and
/// any strong gusts or hard frost. "Rain Sunday and Friday, highs peaking at 12° Thursday.
/// Gusts up to 51 km/h Monday." Built from the rows the list shows, so it never disagrees with them.
public enum WeekOutlook {
    /// Gusts at or above this (km/h) get their own sentence: Environment Canada's wind warning
    /// starts at 70 km/h gusts, but 50 already blows bins over.
    static let gustKmh = 50.0
    /// A low at or below this (°C) is called out as a hard frost.
    static let hardFrostC = -5.0

    public static func text(_ days: [DailyForecast], timeZone: TimeZone, now: Date = Date()) -> String? {
        let week = Array(days.prefix(7))
        guard week.count >= 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "EEEE"
        func name(_ d: DailyForecast) -> String {
            if calendar.isDate(d.date, inSameDayAs: now) { return "today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d.date, inSameDayAs: tomorrow) { return "tomorrow" }
            return fmt.string(from: d.date)
        }
        func list(_ names: [String]) -> String {
            switch names.count {
            case 0: return ""
            case 1: return names[0]
            default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
            }
        }

        // Wet days, by what falls. A day's headline already ignores low chances and trace amounts.
        // Today is left to the Now card and its outlook line: its headline can be this morning's
        // drizzle, long over.
        var rain: [String] = [], snow: [String] = [], mixed: [String] = []
        for d in week where d.condition.isWetOrStorm && !calendar.isDate(d.date, inSameDayAs: now) {
            switch d.precipitationKind {
            case .rain: rain.append(name(d))
            case .snow: snow.append(name(d))
            case .mixed: mixed.append(name(d))
            }
        }
        let wetCount = rain.count + snow.count + mixed.count
        var parts: [String] = []
        if wetCount == 0 {
            parts.append("Dry for the next \(week.count - 1) days")
        } else if wetCount > 3 {
            let noun = snow.isEmpty && mixed.isEmpty ? "Rain" : rain.isEmpty && mixed.isEmpty ? "Snow" : "Rain or snow"
            parts.append("\(noun) on \(wetCount) of the next \(week.count - 1) days")
        } else {
            if !rain.isEmpty { parts.append("Rain \(list(rain))") }
            if !snow.isEmpty { parts.append("snow \(list(snow))") }
            if !mixed.isEmpty { parts.append("rain or snow \(list(mixed))") }
        }
        var first = parts.joined(separator: ", ")
        first = first.prefix(1).uppercased() + first.dropFirst()

        // The warmest day.
        if let warm = week.max(by: { $0.high < $1.high }) {
            first += ", highs peaking at \(WeatherFormat.temperature(warm.high)) \(name(warm))"
        }
        var sentences = [first + "."]

        if let windy = week.filter({ ($0.windGustsMax ?? 0) >= gustKmh }).max(by: { ($0.windGustsMax ?? 0) < ($1.windGustsMax ?? 0) }),
           let g = windy.windGustsMax {
            sentences.append("Gusts up to \(WeatherFormat.wind(g)) \(name(windy)).")
        }
        if let cold = week.min(by: { $0.low < $1.low }), cold.low <= hardFrostC {
            let night = name(cold) == "today" ? "tonight" : "\(name(cold)) night"
            sentences.append("Hard frost \(night), down to \(WeatherFormat.temperature(cold.low)).")
        }
        return sentences.joined(separator: " ")
    }
}
