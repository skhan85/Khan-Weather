import CoreLocation
import SwiftUI
import WidgetKit
import WeatherCore

struct WeatherEntry: TimelineEntry {
    let date: Date
    let current: CurrentConditions?
    let high: Double?
    let low: Double?
    let error: String?

    static let placeholder = WeatherEntry(
        date: Date(),
        current: CurrentConditions(time: Date(), temperature: 21, feelsLike: 23, feelsLikeKind: .apparent,
                                   humidity: 50, windSpeed: 10, windDirection: 270, precipitation: 0,
                                   condition: .partlyCloudy, isDay: true),
        high: 24, low: 14, error: nil)
}

struct WeatherTimelineProvider: TimelineProvider {
    private let provider = OpenMeteoProvider()

    func placeholder(in context: Context) -> WeatherEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (WeatherEntry) -> Void) {
        if context.isPreview { completion(.placeholder); return }
        Task { completion(await loadEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeatherEntry>) -> Void) {
        Task {
            let entry = await loadEntry()
            // Ask iOS to refresh in about 30 minutes; it may wait longer to save battery.
            let next = Date().addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadEntry() async -> WeatherEntry {
        // Widgets can't show a permission prompt; they use the last location iOS knows,
        // which works once the app has been granted location access (NSWidgetWantsLocation).
        let coordinate = CLLocationManager().location.map {
            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        } ?? .fallback
        do {
            let forecast = try await provider.forecast(for: coordinate)
            let today = forecast.daily.first
            return WeatherEntry(date: Date(), current: forecast.current, high: today?.high, low: today?.low, error: nil)
        } catch {
            return WeatherEntry(date: Date(), current: nil, high: nil, low: nil, error: error.localizedDescription)
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
                Label("\(WeatherFormat.temperature(current.temperature)) \(current.condition.description)",
                      systemImage: current.condition.symbolName(isDay: current.isDay))
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: current.condition.symbolName(isDay: current.isDay))
                    Text(WeatherFormat.temperature(current.temperature)).font(.headline)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label(WeatherFormat.temperature(current.temperature),
                          systemImage: current.condition.symbolName(isDay: current.isDay))
                        .font(.headline)
                    Text("Feels \(WeatherFormat.temperature(current.feelsLike))")
                    Text("H \(WeatherFormat.temperature(entry.high))  L \(WeatherFormat.temperature(entry.low))")
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: current.condition.symbolName(isDay: current.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.title2)
                    Text(WeatherFormat.temperature(current.temperature))
                        .font(.system(size: 40, weight: .light))
                    Text(current.condition.description)
                        .font(.caption)
                        .lineLimit(1)
                    Text("Feels \(WeatherFormat.temperature(current.feelsLike))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("H \(WeatherFormat.temperature(entry.high))  L \(WeatherFormat.temperature(entry.low))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        StaticConfiguration(kind: "KhanWeatherCurrent", provider: WeatherTimelineProvider()) { entry in
            KhanWeatherWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Current weather")
        .description("Temperature, feels-like and today's high and low where you are.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
