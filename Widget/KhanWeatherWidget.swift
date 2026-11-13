import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit
import WeatherCore

struct WeatherEntry: TimelineEntry {
    let date: Date
    let current: CurrentConditions?
    let high: Double?
    let low: Double?
    let placeName: String?
    let error: String?
    /// "Rain in 25 min" when precipitation starts or stops within 2 hours.
    var nowcast: String? = nil
    /// Title of the most serious active alert, e.g. "Wind warning".
    var alert: String? = nil
    /// Chosen in Edit Widget; the widget can't read the app's settings without an App Group.
    var unit: TemperatureUnit = .celsius

    static let placeholder = WeatherEntry(
        date: Date(),
        current: CurrentConditions(time: Date(), temperature: 21, feelsLike: 23, feelsLikeKind: .apparent,
                                   humidity: 50, windSpeed: 10, windDirection: 270, precipitation: 0,
                                   condition: .partlyCloudy, isDay: true),
        high: 24, low: 14, placeName: "Toronto", error: nil)
}

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
    private let observations = CanadaObservationProvider()
    private let alerts = ECCCAlertProvider()

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

    private func loadEntry() async -> WeatherEntry {
        // Widgets can't show a permission prompt; they use the last location iOS knows,
        // which works once the app has been granted location access (NSWidgetWantsLocation).
        let coordinate = CLLocationManager().location.map {
            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        } ?? .fallback
        async let place = PlaceNameResolver.name(for: coordinate)
        async let observed = try? observations.observation(near: coordinate)
        async let active = try? alerts.alerts(near: coordinate)
        do {
            let forecast = try await provider.forecast(for: coordinate).applying(await observed ?? nil)
            let today = forecast.daily.first
            return WeatherEntry(date: Date(), current: forecast.current, high: today?.high, low: today?.low,
                                placeName: await place, error: nil, nowcast: forecast.nowcast()?.shortText,
                                alert: await active?.first?.title)
        } catch {
            return WeatherEntry(date: Date(), current: nil, high: nil, low: nil, placeName: await place,
                                error: error.localizedDescription)
        }
    }
}

struct KhanWeatherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WeatherEntry

    var body: some View {
        if let current = entry.current {
            switch family {
            case .accessoryInline:
                Label("\(WeatherFormat.temperature(current.temperature, unit: entry.unit)) \(current.condition.description)",
                      systemImage: current.condition.symbolName(isDay: current.isDay))
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: current.condition.symbolName(isDay: current.isDay))
                    Text(WeatherFormat.temperature(current.temperature, unit: entry.unit)).font(.headline)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label(WeatherFormat.temperature(current.temperature, unit: entry.unit),
                          systemImage: current.condition.symbolName(isDay: current.isDay))
                        .font(.headline)
                    if let alert = entry.alert {
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .lineLimit(1)
                    }
                    Text("Feels \(WeatherFormat.temperature(current.feelsLike, unit: entry.unit))")
                    Text(entry.nowcast ?? "H \(WeatherFormat.temperature(entry.high, unit: entry.unit))  L \(WeatherFormat.temperature(entry.low, unit: entry.unit))")
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        ConditionIcon(condition: current.condition, isDay: current.isDay)
                            .font(.title3)
                        if let place = entry.placeName {
                            Text(place)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    Text(WeatherFormat.temperature(current.temperature, unit: entry.unit))
                        .font(.system(size: 40, weight: .light))
                    Text(entry.nowcast ?? current.condition.description)
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Feels \(WeatherFormat.temperature(current.feelsLike, unit: entry.unit))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let alert = entry.alert {
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Text("H \(WeatherFormat.temperature(entry.high, unit: entry.unit))  L \(WeatherFormat.temperature(entry.low, unit: entry.unit))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Weather unavailable")
                .font(.caption)
        }
    }
}

@main
struct KhanWeatherWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "KhanWeatherCurrent", intent: WeatherWidgetIntent.self,
                               provider: WeatherTimelineProvider()) { entry in
            KhanWeatherWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Current weather")
        .description("Temperature, feels-like, today's high and low, and weather alerts where you are.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
