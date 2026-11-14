import AppIntents
import CoreLocation
import SwiftUI
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

struct WeatherWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Weather"
    static var description = IntentDescription("Choose the temperature unit.")

    @Parameter(title: "Temperature unit", default: .celsius)
    var temperatureUnit: WidgetTemperatureUnit
}

struct WeatherTimelineProvider: AppIntentTimelineProvider {
    private let provider = OpenMeteoProvider()
    private let observations = HyperlocalObservationProvider()
    private let alerts = WorldAlertProvider()

    func placeholder(in context: Context) -> WeatherEntry { .placeholder }

    func snapshot(for configuration: WeatherWidgetIntent, in context: Context) async -> WeatherEntry {
        var entry: WeatherEntry = context.isPreview ? .placeholder : await loadEntry()
        entry.unit = configuration.temperatureUnit.unit
        return entry
    }

    func timeline(for configuration: WeatherWidgetIntent, in context: Context) async -> Timeline<WeatherEntry> {
        var entry = await loadEntry()
        entry.unit = configuration.temperatureUnit.unit
        // Ask iOS to refresh in about 30 minutes; it may wait longer to save battery.
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    /// Runs `operation`, giving up with nil after `seconds`.
    private static func withDeadline<T>(_ seconds: Double, _ operation: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The next 6 hours, with the first showing the same "now" as the app.
    private static func hoursStartingNow(_ forecast: Forecast) -> [HourlyForecast] {
        forecast.hoursStartingNow(count: 6)
    }

    private func loadEntry() async -> WeatherEntry {
        // Widgets can't show a permission prompt; they use the last location iOS knows,
        // which works once the app has been granted location access (NSWidgetWantsLocation).
        let coordinate = CLLocationManager().location.map {
            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        } ?? .fallback
        async let place = PlaceNameResolver.name(for: coordinate)
        // Extras get a hard deadline: if a station or alert service is slow, iOS would otherwise
        // give up on the whole refresh and keep showing an old widget.
        let observations = self.observations
        let alerts = self.alerts
        async let observed = Self.withDeadline(8) { try? await observations.observation(near: coordinate) }
        async let active = Self.withDeadline(8) { try? await alerts.alerts(near: coordinate) }
        async let radarNow = Self.withDeadline(6) { try? await ECCCRadarProvider().now(at: coordinate) }
        do {
            let forecast = try await provider.forecast(for: coordinate).applying(await observed)
                .applyingRadar(await radarNow)
            let today = forecast.daily.first
            return WeatherEntry(date: Date(), current: forecast.current, high: today?.high, low: today?.low,
                                placeName: await place, error: nil, nowcast: forecast.nowcast()?.shortText,
                                alert: await active?.first?.title,
                                hours: Self.hoursStartingNow(forecast), days: Array(forecast.daily.prefix(5)),
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
