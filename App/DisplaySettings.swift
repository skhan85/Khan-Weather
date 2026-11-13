import SwiftUI

/// Look-and-feel choices from Settings, stored in UserDefaults.
enum Appearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ClockStyle: String, CaseIterable {
    case automatic, twelveHour, twentyFourHour

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }
}

enum MainTemperature: String, CaseIterable {
    case actual, feelsLike

    var label: String { self == .actual ? "Actual" : "Feels like" }
}

enum DisplaySettings {
    static let appearanceKey = "appearance"
    static let clockKey = "clockStyle"
    static let mainTemperatureKey = "mainTemperature"
    static let hourlyCountKey = "hourlyCount"
    static let showDetailsKey = "showTodayDetails"

    static var clock: ClockStyle {
        UserDefaults.standard.string(forKey: clockKey).flatMap(ClockStyle.init) ?? .automatic
    }
}

/// Clock times that follow the 12/24-hour setting.
enum TimeText {
    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        if pattern.contains("a") {
            f.amSymbol = "am"
            f.pmSymbol = "pm"
        }
        return f
    }

    /// "3 pm" or "15:00".
    static func hour(_ date: Date, _ timeZone: TimeZone) -> String {
        switch DisplaySettings.clock {
        case .automatic: return date.formatted(Date.FormatStyle(timeZone: timeZone).hour())
        case .twelveHour: return formatter("h a", timeZone).string(from: date)
        case .twentyFourHour: return formatter("HH:00", timeZone).string(from: date)
        }
    }

    /// "3:42 pm" or "15:42".
    static func time(_ date: Date, _ timeZone: TimeZone) -> String {
        switch DisplaySettings.clock {
        case .automatic: return date.formatted(Date.FormatStyle(time: .shortened, timeZone: timeZone))
        case .twelveHour: return formatter("h:mm a", timeZone).string(from: date)
        case .twentyFourHour: return formatter("HH:mm", timeZone).string(from: date)
        }
    }
}
