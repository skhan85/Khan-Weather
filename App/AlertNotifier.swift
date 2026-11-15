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
    static let frostKey = "frostNotifications"
    private static let lastFrostDayKey = "lastFrostNotificationDay"
    private static let lastRainKey = "lastRainNotification"
    private static let lastLocationKey = "lastCurrentLocation"
    private static let notifiedKey = "notifiedAlertIDs"
    static let lastBackgroundCheckKey = "lastBackgroundCheck"

    private static var defaults: UserDefaults { .standard }
    static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    static var rainEnabled: Bool { defaults.bool(forKey: rainKey) }
    static var frostEnabled: Bool { defaults.bool(forKey: frostKey) }

    // MARK: Scheduling

    /// Asks iOS for the next background check. iOS decides the actual time.
    static func schedule() {
        guard isEnabled || rainEnabled || frostEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// When iOS last let the app check in the background, for the status rows in Settings.
    static var lastBackgroundCheck: Date? { defaults.object(forKey: lastBackgroundCheckKey) as? Date }

    /// The app was installed again (sideloading does this often) and iOS forgot the permission,
    /// but the switches are still on: ask again so they mean something.
    static func ensurePermission() async {
        guard isEnabled || rainEnabled || frostEnabled else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined { _ = await requestPermission() }
        schedule()
    }

    /// A notification right now, so the person can see banners and sounds work.
    static func sendTest() async {
        _ = await requestPermission()
        let content = UNMutableNotificationContent()
        content.title = "Khan Weather test"
        content.body = "Notifications from Khan Weather reach this phone."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "test-\(Int(Date().timeIntervalSince1970))", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
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
        defaults.set(Date(), forKey: lastBackgroundCheckKey)
        async let alerts: Void = check()
        async let rain: Void = checkForecast()
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
    /// One forecast fetch for the rain and frost heads-ups at the last known location.
    static func checkForecast(provider: OpenMeteoProvider = OpenMeteoProvider()) async {
        guard rainEnabled || frostEnabled, let here = lastLocation,
              let forecast = try? await provider.forecast(for: here) else { return }
        if rainEnabled { await checkRain(forecast) }
        if frostEnabled { await checkFrost(forecast) }
    }

    private static func checkRain(_ forecast: Forecast) async {
        let last = defaults.object(forKey: lastRainKey) as? Date
        guard let nowcast = RainHeadsUp.shouldNotify(forecast.nowcast(), lastNotified: last),
              // Only when most models also see it, so one model's stray shower doesn't buzz the phone.
              ModelAgreement.wetAgrees(forecast.hourly) else { return }
        defaults.set(Date(), forKey: lastRainKey)
        let content = UNMutableNotificationContent()
        content.title = nowcast.kind == .snow ? "Snow on the way" : "Rain on the way"
        content.body = RainHeadsUp.body(nowcast, timeZone: forecast.timeZone)
        content.sound = .default
        content.threadIdentifier = "rain"
        let request = UNNotificationRequest(identifier: "rain-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// "Frost likely tonight", once a day, in the afternoon or evening, when most models agree.
    private static func checkFrost(_ forecast: Forecast, now: Date = Date()) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let hour = calendar.component(.hour, from: now)
        let today = AccuracyLog.dayString(now, timeZone: forecast.timeZone)
        guard (14...22).contains(hour), defaults.string(forKey: lastFrostDayKey) != today,
              let frost = ModelAgreement.frost(forecast, now: now) else { return }
        defaults.set(today, forKey: lastFrostDayKey)
        let content = UNMutableNotificationContent()
        content.title = "Frost likely tonight"
        content.body = "\(frost.agreeing) of \(frost.total) forecast models drop to \(WeatherFormat.temperature(0)) or below by about \(TimeText.hour(frost.time, forecast.timeZone)). Cover plants and watch for icy spots."
        content.sound = .default
        content.threadIdentifier = "frost"
        let request = UNNotificationRequest(identifier: "frost-\(today)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Opening the app shows the same "rain starting" line, so don't repeat it as a notification.
    static func markRainSeen(_ nowcast: Nowcast?) {
        guard let nowcast, case .starting = nowcast.change else { return }
        defaults.set(Date(), forKey: lastRainKey)
    }
}

/// Without a delegate iOS hides notifications while the app is open, which made the test
/// notification look broken.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
