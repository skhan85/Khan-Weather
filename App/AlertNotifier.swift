import BackgroundTasks
import CoreLocation
import Foundation
import UserNotifications
import WeatherCore

/// Severe weather notifications without a server: iOS wakes the app now and then, the app asks
/// the official alert services about the current location and saved places, and posts a local
/// notification for anything new.
enum AlertNotifier {
    static let taskID = "com.skhan85.KhanWeather.alerts"
    static let enabledKey = "alertNotifications"
    static let advisoriesKey = "alertNotificationsAdvisories"
    static let rainKey = "rainNotifications"
    private static let lastRainKey = "lastRainNotification"
    private static let lastLocationKey = "lastCurrentLocation"
    private static let notifiedKey = "notifiedAlertIDs"

    private static var defaults: UserDefaults { .standard }
    static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    static var rainEnabled: Bool { defaults.bool(forKey: rainKey) }

    // MARK: Scheduling

    /// Asks iOS for the next background check. iOS decides the actual time.
    static func schedule() {
        guard isEnabled || rainEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Places

    /// The app remembers where "current location" last was, since a background check
    /// can't wait for a fresh GPS fix.
    static func rememberCurrentLocation(_ c: Coordinate) {
        defaults.set([c.latitude, c.longitude], forKey: lastLocationKey)
    }

    private static var lastLocation: Coordinate? {
        guard let a = defaults.array(forKey: lastLocationKey) as? [Double], a.count == 2 else { return nil }
        return Coordinate(latitude: a[0], longitude: a[1])
    }

    private static func places() -> [(name: String, coordinate: Coordinate)] {
        var list: [(String, Coordinate)] = []
        if let here = lastLocation { list.append(("your location", here)) }
        if let data = defaults.data(forKey: "savedPlaces"),
           let saved = try? JSONDecoder().decode([SavedPlace].self, from: data) {
            list += saved.map { ($0.name, $0.coordinate) }
        }
        return list
    }

    // MARK: Checking

    /// Alerts already notified or already seen in the app, with when to forget them.
    private static var notified: [String: Double] {
        get { defaults.dictionary(forKey: notifiedKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: notifiedKey) }
    }

    /// Alerts shown on screen don't need a notification later.
    static func markSeen(_ alerts: [WeatherAlert]) {
        var seen = notified
        for a in alerts { seen[a.id] = forgetTime(a) }
        notified = seen
    }

    private static func forgetTime(_ a: WeatherAlert) -> Double {
        (a.expiresAt ?? a.eventEndsAt ?? Date().addingTimeInterval(2 * 86400)).timeIntervalSince1970 + 86400
    }

    static func shouldNotify(_ a: WeatherAlert, includeAdvisories: Bool) -> Bool {
        switch a.kind {
        case .warning, .watch: return true
        case .advisory, .statement, .other: return includeAdvisories
        }
    }

    /// Everything a background wake should do.
    static func checkAll() async {
        async let alerts: Void = check()
        async let rain: Void = checkRain()
        _ = await (alerts, rain)
    }

    static func check(provider: AlertProvider = WorldAlertProvider()) async {
        guard isEnabled else { return }
        let includeAdvisories = defaults.bool(forKey: advisoriesKey)
        var seen = notified.filter { $0.value > Date().timeIntervalSince1970 }
        for place in places() {
            guard let alerts = try? await provider.alerts(near: place.coordinate) else { continue }
            for a in alerts where seen[a.id] == nil && shouldNotify(a, includeAdvisories: includeAdvisories) {
                seen[a.id] = forgetTime(a)
                await post(a, place: place.name)
            }
        }
        notified = seen
    }

    private static func post(_ a: WeatherAlert, place: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(a.title) for \(place)"
        let firstParagraph = a.text.components(separatedBy: "\n\n").first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? a.text
        content.body = String(firstParagraph.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        content.sound = .default
        content.threadIdentifier = place
        let request = UNNotificationRequest(identifier: a.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Rain and snow starting soon

    /// Looks at the next two hours at the last known location and posts a heads-up when rain
    /// or snow is about to start. One per wet spell.
    static func checkRain(provider: OpenMeteoProvider = OpenMeteoProvider()) async {
        guard rainEnabled, let here = lastLocation,
              let forecast = try? await provider.forecast(for: here) else { return }
        let last = defaults.object(forKey: lastRainKey) as? Date
        guard let nowcast = RainHeadsUp.shouldNotify(forecast.nowcast(), lastNotified: last) else { return }
        defaults.set(Date(), forKey: lastRainKey)
        let content = UNMutableNotificationContent()
        content.title = nowcast.kind == .snow ? "Snow on the way" : "Rain on the way"
        content.body = RainHeadsUp.body(nowcast, timeZone: forecast.timeZone)
        content.sound = .default
        content.threadIdentifier = "rain"
        let request = UNNotificationRequest(identifier: "rain-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Opening the app shows the same "rain starting" line, so don't repeat it as a notification.
    static func markRainSeen(_ nowcast: Nowcast?) {
        guard let nowcast, case .starting = nowcast.change else { return }
        defaults.set(Date(), forKey: lastRainKey)
    }
}
