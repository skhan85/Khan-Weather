import AppIntents
import CoreLocation
import SwiftUI
import UserNotifications
import WidgetKit
import WeatherCore

/// The widget can't read the app's settings (no App Group on a free Apple ID), so it has its own
/// units choice. "Same as phone" uses the phone's region, as the app's first-launch question does.
enum WidgetUnits: String, AppEnum {
    case phone, canadian, us, uk

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Units"
    static var caseDisplayRepresentations: [WidgetUnits: DisplayRepresentation] = [
        .phone: "Same as phone's region",
        .canadian: "Canadian (°C, km/h, mm)",
        .us: "US (°F, mph, in)",
        .uk: "UK (°C, mph, mm)",
    ]

    var settings: UnitSettings {
        switch self {
        case .phone: return UnitPreset.deviceDefault.settings
        case .canadian: return UnitPreset.canadian.settings
        case .us: return UnitPreset.us.settings
        case .uk: return UnitPreset.uk.settings
        }
    }
}

enum WidgetAlertNotifications: String, AppEnum {
    case off, warnings, all

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Alert notifications"
    static var caseDisplayRepresentations: [WidgetAlertNotifications: DisplayRepresentation] = [
        .off: "Off",
        .warnings: "Warnings and watches",
        .all: "All alerts",
    ]
}

struct WeatherWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Weather"
    static var description = IntentDescription("Choose the units and alert notifications.")

    /// Replaces the old °C/°F-only "Temperature unit" switch.
    @Parameter(title: "Units", default: .phone)
    var units: WidgetUnits

    /// iOS refreshes widgets far more often than it wakes a sideloaded app, so the widget also
    /// checks for alerts where you are and posts them as Khan Weather notifications.
    @Parameter(title: "Alert notifications", default: .all)
    var alertNotifications: WidgetAlertNotifications

    /// Mirrors Settings > Hyperlocal PWS stations in the app. The widget can't read the app's
    /// settings (no App Group on a free Apple ID), so it has its own switch; keep both the same.
    /// A new name (it was `useHyperlocalPWS`, default off), so widgets already on the Home Screen
    /// pick up the new default and match the app.
    @Parameter(title: "Home weather stations", default: true)
    var useHomeStations: Bool
}

/// Alert notifications from the widget. The widget can't read the app's settings or memory (no
/// App Group on a free Apple ID), so it keeps its own list of what it has posted and uses the
/// alert's id as the notification id, which the app also uses, so both don't post the same one.
enum WidgetAlertNotifier {
    private static let seenKey = "widgetNotifiedAlertIDs"

    static func notify(_ alerts: [WeatherAlert], placeName: String?, setting: WidgetAlertNotifications) async {
        guard setting != .off, !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        var seen = (defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]).filter { $0.value > now }
        let delivered = Set(await center.deliveredNotifications().map(\.request.identifier))
        for a in alerts where seen[a.id] == nil {
            switch a.kind {
            case .warning, .watch: break
            case .advisory, .statement, .other: if setting != .all { continue }
            }
            seen[a.id] = (a.expiresAt ?? a.eventEndsAt ?? Date().addingTimeInterval(2 * 86400)).timeIntervalSince1970 + 86400
            if delivered.contains(a.id) { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(a.title) for \(placeName ?? "your location")"
            content.body = a.notificationBody
            content.sound = .default
            content.threadIdentifier = "your location"
            try? await center.add(UNNotificationRequest(identifier: a.id, content: content, trigger: nil))
        }
        defaults.set(seen, forKey: seenKey)
    }
}

struct WeatherTimelineProvider: AppIntentTimelineProvider {
    private let provider = OpenMeteoProvider()
    private let alerts = WorldAlertProvider()

    func placeholder(in context: Context) -> WeatherEntry { .placeholder }

    func snapshot(for configuration: WeatherWidgetIntent, in context: Context) async -> WeatherEntry {
        if context.isPreview { return .placeholder }
        configuration.units.settings.save()
        let loaded = await load(notify: .off, hyperlocal: configuration.useHomeStations)
        return loaded.entries(unit: configuration.units.settings.temperature).first ?? .placeholder
    }

    func timeline(for configuration: WeatherWidgetIntent, in context: Context) async -> Timeline<WeatherEntry> {
        // Saved in the widget's own settings so everything it writes (the rain line, alert
        // notifications) uses the same units as the numbers it draws.
        configuration.units.settings.save()
        let loaded = await load(notify: configuration.alertNotifications,
                                hyperlocal: configuration.useHomeStations)
        let entries = loaded.entries(unit: configuration.units.settings.temperature)
        // iOS gives a widget roughly 40 to 70 refreshes a day and decides the actual times; asking
        // for 15 minutes gets the most it allows. After a failed fetch, ask again sooner.
        let next = loaded.fresh ? WidgetRefresh.interval : WidgetRefresh.retryInterval
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(next)))
    }

    /// What one refresh fetched: the forecast (with the station reading and radar applied, exactly
    /// as the app does) and the extras around it.
    struct Loaded {
        var forecast: Forecast?
        /// False when the fetch failed and `forecast` is the last good one from an earlier refresh.
        var fresh: Bool
        var placeName: String?
        var alert: String?
        var error: String?

        /// One entry now, then one every 5 minutes for half an hour. Each keeps the same "now"
        /// (the latest reading, like the app until it fetches again) but moves the clock-driven
        /// parts on: the rain countdown, the hours starting with the current one, and today's
        /// high and low after midnight. So "Rain in 10 min" doesn't sit there after the rain starts,
        /// even when iOS waits a while before the next refresh.
        func entries(unit: TemperatureUnit, from start: Date = Date()) -> [WeatherEntry] {
            guard let forecast else {
                var e = WeatherEntry(date: start, current: nil, high: nil, low: nil, placeName: placeName, error: error)
                e.unit = unit
                return [e]
            }
            return stride(from: 0, through: WidgetRefresh.entrySpan, by: WidgetRefresh.entryStep).map { offset in
                let date = start.addingTimeInterval(offset)
                let today = forecast.displayDay(at: date)
                var e = WeatherEntry(date: date, current: forecast.current, high: today?.high, low: today?.low,
                                     placeName: placeName, error: nil, nowcast: forecast.nowcast(at: date)?.shortText,
                                     alert: alert,
                                     hours: forecast.hoursStartingNow(from: date, count: 6),
                                     days: Array(forecast.displayDaily(at: date).prefix(5)),
                                     timeZone: forecast.timeZone)
                e.unit = unit
                e.updatedAt = forecast.fetchedAt
                return e
            }
        }
    }

    private func load(notify: WidgetAlertNotifications, hyperlocal: Bool) async -> Loaded {
        // Widgets can't show a permission prompt; they use the last location iOS knows,
        // which works once the app has been granted location access (NSWidgetWantsLocation).
        let known = CLLocationManager().location.map {
            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        let coordinate = known ?? .fallback
        async let place = PlaceNameResolver.name(for: coordinate)
        // Extras get a hard deadline: if a station or alert service is slow, iOS would otherwise
        // give up on the whole refresh and keep showing an old widget.
        let observations = ObservationSource.provider(hyperlocal: hyperlocal)
        let alerts = self.alerts
        let previous = WidgetObservationMemory.last(near: coordinate)
        async let observed = Deadline.run(8) { try? await observations.observation(near: coordinate) }?
            .smoothed(after: previous)
        async let active = Deadline.run(8) { try? await alerts.alerts(near: coordinate) }
        async let radarNow = Deadline.run(6) { try? await ECCCRadarProvider().now(at: coordinate) }
        // Only for a real location: the Toronto fallback isn't where the person is.
        if known != nil, let found = await active {
            await WidgetAlertNotifier.notify(found, placeName: await place, setting: notify)
        }
        let alertTitle = await active?.first?.title
        do {
            let obs = await observed
            if let obs { WidgetObservationMemory.remember(obs, near: coordinate) }
            // Same order as the app: the station reading re-weights the blend only when it's local.
            let forecast = try await provider.forecast(for: coordinate, anchor: obs?.blendAnchor)
                .applying(obs)
                .applyingRadar(await radarNow)
            WidgetForecastMemory.remember(forecast)
            return Loaded(forecast: forecast, fresh: true, placeName: await place, alert: alertTitle)
        } catch {
            // A failed fetch (no signal, a busy server) keeps showing the last good forecast for this
            // spot rather than "Weather unavailable", and asks iOS to try again soon.
            if let last = WidgetForecastMemory.last(near: coordinate) {
                return Loaded(forecast: last, fresh: false, placeName: await place, alert: alertTitle)
            }
            return Loaded(forecast: nil, fresh: false, placeName: await place, alert: alertTitle,
                          error: error.localizedDescription)
        }
    }
}

/// How often the widget asks to refresh, and how far ahead each refresh lays out entries.
enum WidgetRefresh {
    static let interval: TimeInterval = 15 * 60
    static let retryInterval: TimeInterval = 5 * 60
    static let entryStep: TimeInterval = 5 * 60
    static let entrySpan: TimeInterval = 30 * 60
}

/// The widget's last good forecast, shown when a refresh can't reach the servers. Only used for
/// the same spot (within about 3 km) and for 3 hours; older than that it says it's unavailable.
enum WidgetForecastMemory {
    private static let key = "widgetLastForecast"
    static let maxAge: TimeInterval = 3 * 3600

    static func remember(_ f: Forecast) {
        guard let data = try? JSONEncoder().encode(f) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func last(near c: Coordinate, now: Date = Date()) -> Forecast? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let f = try? JSONDecoder().decode(Forecast.self, from: data),
              now.timeIntervalSince(f.fetchedAt) < maxAge,
              EnvironmentCanadaProvider.distanceKm(f.location, c) < 3 else { return nil }
        return f
    }
}

/// Reads the widget size from the environment and draws the shared widget view.
struct KhanWeatherWidgetRoot: View {
    @Environment(\.widgetFamily) private var family
    let entry: WeatherEntry

    var body: some View {
        KhanWeatherWidgetView(entry: entry, family: family)
    }
}

@main
struct KhanWeatherWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "KhanWeatherCurrent", intent: WeatherWidgetIntent.self,
                               provider: WeatherTimelineProvider()) { entry in
            KhanWeatherWidgetRoot(entry: entry)
                .containerBackground(for: .widget) { WidgetSky(entry: entry) }
        }
        .configurationDisplayName("Current weather")
        .description("Temperature, feels-like and conditions where you are. Home Screen sizes add the next few hours, the week ahead and alerts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

/// The widget's last station reading for a spot, so it smooths home-station wobble the same way
/// the app does (`Observation.smoothed(after:)`).
enum WidgetObservationMemory {
    private static let key = "widgetLastObservation"

    private static func spot(_ c: Coordinate) -> String {
        String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    static func last(near c: Coordinate) -> Observation? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([String: Observation].self, from: data) else { return nil }
        return saved[spot(c)]
    }

    static func remember(_ o: Observation, near c: Coordinate) {
        guard let data = try? JSONEncoder().encode([spot(c): o]) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
