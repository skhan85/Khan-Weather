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
    static let lastBackgroundReasonKey = "lastBackgroundReason"

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
    static var lastBackgroundReason: String? { defaults.string(forKey: lastBackgroundReasonKey) }
    static var anyEnabled: Bool { isEnabled || rainEnabled || frostEnabled }

    /// The app was installed again (sideloading does this often) and iOS forgot the permission,
    /// but the switches are still on: ask again so they mean something.
    static func ensurePermission() async {
        guard isEnabled || rainEnabled || frostEnabled else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined { _ = await requestPermission() }
        schedule()
    }

    /// What happened to the test notification, for the line under the button.
    enum TestResult: Equatable {
        case delivered, notDelivered, failed(String)
    }

    static let testDelay: TimeInterval = 5

    /// A notification in a few seconds (time to lock the phone and watch for it), then whether iOS
    /// actually delivered it. Delivered but not seen means a Focus or the notification style hid it.
    static func sendTest() async -> TestResult {
        _ = await requestPermission()
        let center = UNUserNotificationCenter.current()
        let id = "test-\(Int(Date().timeIntervalSince1970))"
        let content = UNMutableNotificationContent()
        content.title = "Khan Weather test"
        content.body = "Notifications from Khan Weather reach this phone."
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: testDelay, repeats: false))
        do {
            try await center.add(request)
        } catch {
            return .failed(error.localizedDescription)
        }
        try? await Task.sleep(nanoseconds: UInt64((testDelay + 2) * 1_000_000_000))
        let delivered = await center.deliveredNotifications().contains { $0.request.identifier == id }
        return delivered ? .delivered : .notDelivered
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
    static func checkAll(reason: String = "background refresh") async {
        defaults.set(Date(), forKey: lastBackgroundCheckKey)
        defaults.set(reason, forKey: lastBackgroundReasonKey)
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
        content.body = a.notificationBody
        content.sound = .default
        content.threadIdentifier = place
        let center = UNUserNotificationCenter.current()
        // The widget may have posted this one already (it checks alerts too, with the same id).
        if await center.deliveredNotifications().contains(where: { $0.request.identifier == a.id }) { return }
        try? await center.add(UNNotificationRequest(identifier: a.id, content: content, trigger: nil))
    }

    // MARK: Rain, snow and frost heads-ups

    private static let scheduledRainKey = "scheduledRainNotification"
    private static let scheduledFrostKey = "scheduledFrostNotification"
    private static let rainAheadID = "rain-ahead"
    private static let frostAheadID = "frost-ahead"

    /// One forecast fetch for the rain and frost heads-ups at the last known location. Besides
    /// posting what's due now, it schedules what's coming (rain later today, frost tonight) as
    /// timed notifications, because iOS may not wake the app again before then. Every run
    /// replaces those with the newest forecast. `foreground` skips the "starting now" rain post,
    /// since the app shows that line on screen.
    static func checkForecast(provider: OpenMeteoProvider = OpenMeteoProvider(), foreground: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        guard rainEnabled || frostEnabled, let here = lastLocation,
              let forecast = try? await provider.forecast(for: here) else {
            if !rainEnabled { center.removePendingNotificationRequests(withIdentifiers: [rainAheadID]) }
            if !frostEnabled { center.removePendingNotificationRequests(withIdentifiers: [frostAheadID]) }
            return
        }
        settleScheduled()
        if rainEnabled { await checkRain(forecast, foreground: foreground) }
        else { center.removePendingNotificationRequests(withIdentifiers: [rainAheadID]) }
        if frostEnabled { await checkFrost(forecast) }
        else { center.removePendingNotificationRequests(withIdentifiers: [frostAheadID]) }
    }

    /// A scheduled heads-up whose time has passed has been shown: count it as sent. One still in the
    /// future is dropped here and planned again from the newer forecast.
    private static func settleScheduled(now: Date = Date()) {
        if let at = defaults.object(forKey: scheduledRainKey) as? Date {
            if at <= now { defaults.set(at, forKey: lastRainKey) }
            defaults.removeObject(forKey: scheduledRainKey)
        }
        if let a = defaults.array(forKey: scheduledFrostKey), a.count == 2,
           let at = a[0] as? Date, let day = a[1] as? String {
            if at <= now { defaults.set(day, forKey: lastFrostDayKey) }
            defaults.removeObject(forKey: scheduledFrostKey)
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [rainAheadID, frostAheadID])
    }

    private static func checkRain(_ forecast: Forecast, foreground: Bool, now: Date = Date()) async {
        let last = defaults.object(forKey: lastRainKey) as? Date
        if let last, now.timeIntervalSince(last) < RainHeadsUp.quietPeriod { return }
        let nowcast = forecast.nowcast(at: now)

        // Starting within the hour: say so now (unless the app is open and already shows it).
        if let soon = RainHeadsUp.shouldNotify(nowcast, lastNotified: last, now: now),
           ModelAgreement.wetAgrees(forecast.hourly, now: now) {
            guard !foreground else { return }
            defaults.set(now, forKey: lastRainKey)
            let content = UNMutableNotificationContent()
            content.title = soon.kind == .snow ? "Snow on the way" : "Rain on the way"
            content.body = RainHeadsUp.body(soon, at: now, timeZone: forecast.timeZone)
            content.sound = .default
            content.threadIdentifier = "rain"
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "rain-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil))
            return
        }

        // Later: the 15-minute nowcast (next 2 hours) first, then the hourly forecast up to 6 hours.
        var start: Date?
        var snow = false
        if let nowcast, case .starting(let minutes) = nowcast.change {
            start = now.addingTimeInterval(Double(minutes) * 60)
            snow = nowcast.kind == .snow
        } else if let hour = RainHeadsUp.upcomingWetHour(forecast.hourly, now: now, from: 3600) {
            start = hour.time
            snow = hour.snow
        }
        guard let start else { return }
        let fireAt = start.addingTimeInterval(-20 * 60)
        guard fireAt > now.addingTimeInterval(60) else { return }
        let f = DateFormatter()
        f.timeZone = forecast.timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        let content = UNMutableNotificationContent()
        content.title = snow ? "Snow on the way" : "Rain on the way"
        content.body = "\(snow ? "Snow" : "Rain") expected to start around \(f.string(from: start)). Open the app for the latest."
        content.sound = .default
        content.threadIdentifier = "rain"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSince(now), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: rainAheadID, content: content, trigger: trigger))
        defaults.set(fireAt, forKey: scheduledRainKey)
    }

    /// "Frost likely tonight", once a day, delivered in the afternoon or evening, when most models agree.
    /// Found in the morning, it's scheduled for 2 PM.
    private static func checkFrost(_ forecast: Forecast, now: Date = Date()) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let hour = calendar.component(.hour, from: now)
        let today = AccuracyLog.dayString(now, timeZone: forecast.timeZone)
        guard hour <= 22, defaults.string(forKey: lastFrostDayKey) != today,
              let frost = ModelAgreement.frost(forecast, now: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Frost likely tonight"
        content.body = "\(frost.agreeing) of \(frost.total) forecast models drop to \(WeatherFormat.temperature(0)) or below by about \(TimeText.hour(frost.time, forecast.timeZone)). Cover plants and watch for icy spots."
        content.sound = .default
        content.threadIdentifier = "frost"
        if hour >= 14 {
            defaults.set(today, forKey: lastFrostDayKey)
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "frost-\(today)", content: content, trigger: nil))
        } else if let at = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now), at > now {
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSince(now), repeats: false)
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: frostAheadID, content: content, trigger: trigger))
            defaults.set([at, today], forKey: scheduledFrostKey)
        }
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
