import AppIntents
import CoreLocation
import SwiftUI
import UserNotifications
import WidgetKit
import WeatherCore

enum WidgetTemperatureUnit: String, AppEnum {
    case celsius, fahrenheit

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Temperature unit"
    static var caseDisplayRepresentations: [WidgetTemperatureUnit: DisplayRepresentation] = [
        .celsius: "°C",
        .fahrenheit: "°F",
    ]

    var unit: TemperatureUnit { self == .celsius ? .celsius : .fahrenheit }
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
    static var description = IntentDescription("Choose the temperature unit.")

    @Parameter(title: "Temperature unit", default: .celsius)
    var temperatureUnit: WidgetTemperatureUnit

    /// iOS refreshes widgets far more often than it wakes a sideloaded app, so the widget also
    /// checks for alerts where you are and posts them as Khan Weather notifications.
    @Parameter(title: "Alert notifications", default: .all)
    var alertNotifications: WidgetAlertNotifications

    /// Mirrors Settings > Hyperlocal PWS stations in the app. The widget can't read the app's
    /// settings (no App Group on a free Apple ID), so it has its own switch; keep both the same.
    @Parameter(title: "Hyperlocal PWS stations", default: false)
    var useHyperlocalPWS: Bool
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
            let first = a.text.components(separatedBy: "\n\n").first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? a.text
            content.body = String(first.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
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
        var entry: WeatherEntry = context.isPreview ? .placeholder : await loadEntry(notify: .off, hyperlocal: configuration.useHyperlocalPWS)
        entry.unit = configuration.temperatureUnit.unit
        return entry
    }

    func timeline(for configuration: WeatherWidgetIntent, in context: Context) async -> Timeline<WeatherEntry> {
        var entry = await loadEntry(notify: configuration.alertNotifications,
                                    hyperlocal: configuration.useHyperlocalPWS)
        entry.unit = configuration.temperatureUnit.unit
        // Ask iOS to refresh in about 30 minutes; it may wait longer to save battery.
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    /// The next 6 hours, with the first showing the same "now" as the app.
    private static func hoursStartingNow(_ forecast: Forecast) -> [HourlyForecast] {
        forecast.hoursStartingNow(count: 6)
    }

    private func loadEntry(notify: WidgetAlertNotifications, hyperlocal: Bool) async -> WeatherEntry {
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
        async let observed = Deadline.run(8) { try? await observations.observation(near: coordinate) }
        async let active = Deadline.run(8) { try? await alerts.alerts(near: coordinate) }
        async let radarNow = Deadline.run(6) { try? await ECCCRadarProvider().now(at: coordinate) }
        // Only for a real location: the Toronto fallback isn't where the person is.
        if known != nil, let found = await active {
            await WidgetAlertNotifier.notify(found, placeName: await place, setting: notify)
        }
        do {
            let obs = await observed
            // Same order as the app: the station reading re-weights the blend only when it's local.
            let forecast = try await provider.forecast(for: coordinate, observedTemperature: obs?.blendAnchor)
                .applying(obs)
                .applyingRadar(await radarNow)
            let days = forecast.displayDaily()
            let today = forecast.displayDay()
            return WeatherEntry(date: Date(), current: forecast.current, high: today?.high, low: today?.low,
                                placeName: await place, error: nil, nowcast: forecast.nowcast()?.shortText,
                                alert: await active?.first?.title,
                                hours: Self.hoursStartingNow(forecast),
                                days: Array(days.prefix(5)),
                                timeZone: forecast.timeZone)
        } catch {
            return WeatherEntry(date: Date(), current: nil, high: nil, low: nil, placeName: await place,
                                error: error.localizedDescription)
        }
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
        .description("Temperature, the next few hours, today's high and low, and weather alerts where you are.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
