import Foundation

/// A one-line clothing tip for the rest of the day, e.g. "Warm jacket, and an umbrella from 1 PM."
public enum WhatToWear {
    /// Looks at the current feels-like and the next `hours` forecast hours (the rest of the outing).
    /// `hourText` formats a time like "1 PM" in the place's time zone and the user's clock setting.
    public static func tip(current: CurrentConditions, upcoming: [HourlyForecast], hours: Int = 12,
                           hourText: (Date) -> String) -> String {
        let window = Array(upcoming.prefix(hours))
        let feels = [current.feelsLike] + window.compactMap { $0.feelsLike ?? $0.temperature }
        let coldest = feels.min() ?? current.feelsLike
        let warmest = feels.max() ?? current.feelsLike

        var extras: [String] = []
        let wetHours = window.filter(isWet)
        if let wet = wetHours.first {
            let hasSnow = wetHours.contains { $0.precipitationKind == .snow || $0.precipitationKind == .mixed }
            let hasRain = wetHours.contains { $0.precipitationKind == .rain || $0.precipitationKind == .mixed }
            let item = (hasSnow && hasRain) ? "boots and an umbrella" : (hasSnow ? "boots" : "an umbrella")
            let starting = wet.time <= current.time.addingTimeInterval(45 * 60) ? "" : " from \(hourText(wet.time))"
            extras.append(item + starting)
        }
        let gusts = max(window.compactMap(\.windGusts).max() ?? 0, current.windGusts ?? 0)
        if gusts >= 50 { extras.append("something windproof") }
        let uv = window.compactMap(\.uvIndex).max() ?? 0
        if uv >= 6 { extras.append("sunscreen") }

        var line = layer(coldest: coldest, warmest: warmest)
        if extras.count == 1 {
            line += ", and " + extras[0]
        } else if extras.count > 1 {
            line += ", " + extras.dropLast().joined(separator: ", ") + ", and " + extras.last!
        }
        return line + "."
    }

    static func isWet(_ h: HourlyForecast) -> Bool {
        (h.precipitationProbability ?? 0) >= 50 || (h.precipitation ?? 0) >= 0.3 || h.condition.isPrecipitation
    }

    /// Dress for the coldest it will feel, and say so when the day warms up a lot.
    static func layer(coldest: Double, warmest: Double) -> String {
        let base: String
        switch coldest {
        case ..<(-15): base = "Heavy winter coat, hat and mitts"
        case ..<(-5): base = "Winter coat, hat and gloves"
        case ..<3: base = "Warm jacket"
        case ..<10: base = "Jacket"
        case ..<16: base = "Light jacket or sweater"
        case ..<24: base = "T-shirt weather"
        default: base = "Shorts weather"
        }
        if warmest - coldest >= 10 && coldest < 16 { return base + " you can shed later" }
        return base
    }
}
