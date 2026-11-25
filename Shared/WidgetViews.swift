import SwiftUI
import Charts
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
    /// The next few days, for the large widget.
    var days: [DailyForecast] = []
    var timeZone: TimeZone = .current
    /// When the numbers were fetched. Shown small on the Lock Screen so it's clear how fresh they are.
    var updatedAt: Date? = nil

    static let placeholder: WeatherEntry = {
        let now = Date()
        var hours: [HourlyForecast] = []
        for i in 1...6 {
            let time: Date = now.addingTimeInterval(Double(i) * 3600)
            let temperature: Double = 6 + Double(i % 3)
            let rainy: Bool = i == 4
            let condition: WeatherCondition = rainy ? .rainShowers : .mainlyClear
            let chance: Double = rainy ? 40 : 0
            hours.append(HourlyForecast(time: time, temperature: temperature,
                                        precipitationProbability: chance, condition: condition, isDay: true))
        }
        return WeatherEntry(
            date: now,
            current: CurrentConditions(time: now, temperature: 6, feelsLike: 3, feelsLikeKind: .windChill,
                                       humidity: 70, windSpeed: 12, windDirection: 270, precipitation: 0,
                                       condition: .mainlyClear, isDay: true),
            high: 9, low: 1, placeName: "Milton", error: nil, hours: hours, days: placeholderDays(now))
    }()
}

private func placeholderDays(_ now: Date) -> [DailyForecast] {
    var days: [DailyForecast] = []
    let highs: [Double] = [9, 7, 3, 4, 6]
    let lows: [Double] = [1, 2, -3, -2, 0]
    let skies: [WeatherCondition] = [.partlyCloudy, .rainShowers, .overcast, .clear, .clear]
    for i in 0..<5 {
        let date: Date = now.addingTimeInterval(Double(i) * 86_400)
        days.append(DailyForecast(date: date, high: highs[i], low: lows[i], condition: skies[i]))
    }
    return days
}

/// The widget's sky: the same gradient as the app.
struct WidgetSky: View {
    let entry: WeatherEntry

    var body: some View {
        ZStack {
            SkyBackground(condition: entry.current?.condition ?? .partlyCloudy, isDay: entry.current?.isDay ?? true)
            // Slightly darker at the bottom so the numbers stand out, like the app's cards.
            LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The Khan Weather "K" mark: a navy K on a gold disc.
struct KMark: View {
    var size: CGFloat = 18

    var body: some View {
        Text("K")
            .font(.system(size: size * 0.66, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.25))
            .frame(width: size, height: size)
            .background(Circle().fill(Brand.gold))
            .accessibilityHidden(true)
    }
}

/// A small gold temperature curve with the numbers on it, for widgets.
struct WidgetCurve: View {
    let hours: [HourlyForecast]
    let unit: TemperatureUnit
    let timeZone: TimeZone

    var body: some View {
        let temps = hours.map(\.temperature)
        let low = temps.min() ?? 0
        let high = temps.max() ?? 0
        let span = max(high - low, 4)
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(hours) { hour in
                    VStack(spacing: 3) {
                        Text(hour.time, format: Date.FormatStyle(timeZone: timeZone).hour())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        IconBadge(condition: hour.condition, isDay: hour.isDay, size: 26)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Chart {
                ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                    LineMark(x: .value("Hour", Double(index)), y: .value("Temp", hour.temperature))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(Brand.gold)
                    PointMark(x: .value("Hour", Double(index)), y: .value("Temp", hour.temperature))
                        .symbolSize(18)
                        .foregroundStyle(.white)
                        .annotation(position: .top, spacing: 2) {
                            Text(WeatherFormat.temperature(hour.temperature, unit: unit))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                }
            }
            .chartXScale(domain: -0.5 ... Double(hours.count) - 0.5)
            .chartYScale(domain: (low - span * 0.3) ... (high + span * 0.9))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
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
                lockInline(current)
            case .accessoryCircular:
                lockCircular(current)
            case .accessoryRectangular:
                lockRectangular(current)
            case .systemMedium:
                HStack(spacing: 12) {
                    summary(current)
                        .frame(width: 118)
                    WidgetCurve(hours: Array(entry.hours.prefix(4)), unit: entry.unit, timeZone: entry.timeZone)
                }
                .environment(\.colorScheme, .dark)
            case .systemLarge:
                large(current)
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

    // MARK: Lock Screen
    //
    // Lock Screen widgets show the same numbers as the app's Now card: the current temperature
    // and feels-like from `entry.current`, the condition, and the place name. iOS tints them to
    // match the clock, so they use type weight and size for hierarchy, not colour.

    private func feelsText(_ current: CurrentConditions) -> String {
        "\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)) \(temp(current.feelsLike))"
    }

    /// One line above the clock: "Milton 7° · Feels like 5°", shortened when space is tight.
    private func lockInline(_ current: CurrentConditions) -> some View {
        let t = temp(current.temperature)
        let f = temp(current.feelsLike)
        let place = entry.placeName.map { "\($0) " } ?? ""
        return ViewThatFits {
            Label("\(place)\(t) · \(feelsText(current))", systemImage: current.condition.symbolName(isDay: current.isDay))
            Label("\(place)\(t) · Feels \(f)", systemImage: current.condition.symbolName(isDay: current.isDay))
            Label("\(t) · Feels \(f)", systemImage: current.condition.symbolName(isDay: current.isDay))
        }
    }

    /// Condition icon, temperature, and feels-like in a disc.
    private func lockCircular(_ current: CurrentConditions) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -1) {
                Image(systemName: current.condition.symbolName(isDay: current.isDay))
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(temp(current.temperature))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("Feels \(temp(current.feelsLike))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.85)
            }
            .padding(.horizontal, 6)
        }
        .widgetAccentable()
    }

    /// City across the top; the temperature large on the left; the condition and feels-like
    /// stacked beside it. An active alert adds a warning sign next to the city.
    private func lockRectangular(_ current: CurrentConditions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(entry.placeName ?? "Current location")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                if let updated = entry.updatedAt {
                    Text(updated, format: .dateTime.hour().minute())
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .opacity(0.7)
                        .accessibilityLabel("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                }
                if entry.alert != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .accessibilityLabel(entry.alert ?? "Weather alert")
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Text(temp(current.temperature))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: current.condition.symbolName(isDay: current.isDay))
                            .symbolRenderingMode(.hierarchical)
                        Text(current.condition.description)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(feelsText(current))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .opacity(0.85)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetAccentable()
    }

    private func summary(_ current: CurrentConditions) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    KMark(size: 16)
                    if let place = entry.placeName {
                        Text(place)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 4)
                IconBadge(condition: current.condition, isDay: current.isDay, size: 38)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(temp(current.temperature))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .layoutPriority(1)
                Text("Feels \(temp(current.feelsLike))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
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

    private func large(_ current: CurrentConditions) -> some View {
        let weekLow = entry.days.map(\.low).min() ?? 0
        let weekHigh = entry.days.map(\.high).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(condition: current.condition, isDay: current.isDay, size: 58)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        KMark(size: 16)
                        if let place = entry.placeName {
                            Text(place).font(.subheadline.weight(.bold)).lineLimit(1)
                        }
                    }
                    Text(temp(current.temperature))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("\(current.condition.description) · feels \(temp(current.feelsLike))")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("H \(temp(entry.high))").font(.subheadline.weight(.bold))
                    Text("L \(temp(entry.low))").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            if let line = entry.alert ?? entry.nowcast {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Brand.gold).frame(width: 3, height: 16)
                    Text(line).font(.caption.weight(.semibold)).lineLimit(1)
                }
            }
            WidgetCurve(hours: Array(entry.hours.prefix(6)), unit: entry.unit, timeZone: entry.timeZone)
                .frame(maxHeight: 110)
            VStack(spacing: 6) {
                ForEach(Array(entry.days.prefix(5).enumerated()), id: \.element.id) { index, day in
                    HStack(spacing: 8) {
                        Text(index == 0 ? "Today" : day.date.formatted(Date.FormatStyle(timeZone: entry.timeZone).weekday(.abbreviated)))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(index == 0 ? Brand.gold : .white)
                            .frame(width: 42, alignment: .leading)
                        IconBadge(condition: day.condition, size: 22, mixed: day.isMixedPrecipitation)
                        Text(temp(day.high))
                            .font(.caption.weight(.bold))
                            .frame(width: 30, alignment: .trailing)
                        TemperatureRangeBar(low: day.low, high: day.high, weekLow: weekLow, weekHigh: weekHigh)
                        Text(temp(day.low))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 30, alignment: .leading)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .fontDesign(.rounded)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
