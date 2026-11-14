import SwiftUI
import WidgetKit
import WeatherCore

/// What the widget shows. Lives in Shared so the app's design preview can draw the same widget.
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
    /// The next few hours, for the medium widget.
    var hours: [HourlyForecast] = []
    var timeZone: TimeZone = .current

    static let placeholder: WeatherEntry = {
        let now = Date()
        var hours: [HourlyForecast] = []
        for i in 1...5 {
            let time: Date = now.addingTimeInterval(Double(i) * 3600)
            let temperature: Double = 21 + Double(i % 3)
            let rainy: Bool = i == 4
            let condition: WeatherCondition = rainy ? .rainShowers : .partlyCloudy
            let chance: Double = rainy ? 40 : 0
            hours.append(HourlyForecast(time: time, temperature: temperature,
                                        precipitationProbability: chance, condition: condition, isDay: true))
        }
        return WeatherEntry(
            date: now,
            current: CurrentConditions(time: now, temperature: 21, feelsLike: 23, feelsLikeKind: .apparent,
                                       humidity: 50, windSpeed: 10, windDirection: 270, precipitation: 0,
                                       condition: .partlyCloudy, isDay: true),
            high: 24, low: 14, placeName: "Toronto", error: nil, hours: hours)
    }()
}

/// The widget's sky: the same gradient as the app.
struct WidgetSky: View {
    let entry: WeatherEntry

    var body: some View {
        SkyBackground(condition: entry.current?.condition ?? .partlyCloudy, isDay: entry.current?.isDay ?? true)
    }
}

struct KhanWeatherWidgetView: View {
    let entry: WeatherEntry
    let family: WidgetFamily

    private func temp(_ c: Double?) -> String { WeatherFormat.temperature(c, unit: entry.unit) }

    var body: some View {
        if let current = entry.current {
            switch family {
            case .accessoryInline:
                Label([entry.placeName, temp(current.temperature), current.condition.description]
                        .compactMap { $0 }.joined(separator: " "),
                      systemImage: current.condition.symbolName(isDay: current.isDay))
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: current.condition.symbolName(isDay: current.isDay))
                    Text(temp(current.temperature)).font(.headline)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        Label(temp(current.temperature), systemImage: current.condition.symbolName(isDay: current.isDay))
                            .font(.headline)
                        if let place = entry.placeName {
                            Text(place)
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    if let alert = entry.alert {
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .lineLimit(1)
                    }
                    Text("Feels \(temp(current.feelsLike))")
                    Text(entry.nowcast ?? "H \(temp(entry.high))  L \(temp(entry.low))")
                }
            case .systemMedium:
                HStack(spacing: 12) {
                    summary(current)
                    hourly
                }
                .environment(\.colorScheme, .dark)
            default:
                summary(current)
                    .environment(\.colorScheme, .dark)
            }
        } else {
            Text("Weather unavailable")
                .font(.caption)
                .foregroundStyle(.white)
        }
    }

    private func summary(_ current: CurrentConditions) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                if let place = entry.placeName {
                    Text(place)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                IconBadge(condition: current.condition, isDay: current.isDay, size: 38)
            }
            Spacer(minLength: 0)
            Text(temp(current.temperature))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
            Text(entry.nowcast ?? current.condition.description)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let alert = entry.alert {
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "thermometer.medium").foregroundStyle(Brand.gold)
                    Text("\(temp(entry.high)) / \(temp(entry.low))")
                }
                .font(.caption.weight(.bold))
            }
        }
        .foregroundStyle(.white)
        .fontDesign(.rounded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }

    private var hourly: some View {
        HStack(spacing: 6) {
            ForEach(entry.hours.prefix(4)) { hour in
                VStack(spacing: 6) {
                    Text(hour.time, format: Date.FormatStyle(timeZone: entry.timeZone).hour())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    IconBadge(condition: hour.condition, isDay: hour.isDay, size: 30)
                    Text(temp(hour.temperature))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
