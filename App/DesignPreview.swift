import SwiftUI
import WidgetKit
import WeatherCore

/// A sample sheet of icons, skies and widgets, shown only when the app is launched with
/// `-designPreview`. CI uses it to take screenshots of looks that depend on the weather,
/// since there's no Mac to preview them on.
struct DesignPreview: View {
    private let samples: [(WeatherCondition, Bool)] = [
        (.clear, true), (.partlyCloudy, true), (.rain, true), (.snow, true),
        (.thunderstorm, true), (.overcast, true), (.clear, false), (.rainShowers, false),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Lock Screen").font(.headline)
                lockScreen
                Text("Widgets").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
                    ForEach(samples.indices, id: \.self) { i in
                        widget(samples[i].0, isDay: samples[i].1, family: .systemSmall)
                            .frame(width: 158, height: 158)
                    }
                }
                widget(.partlyCloudy, isDay: true, family: .systemMedium)
                    .frame(width: 338, height: 158)
                widget(.clear, isDay: false, family: .systemMedium)
                    .frame(width: 338, height: 158)
                widget(.partlyCloudy, isDay: true, family: .systemLarge)
                    .frame(width: 338, height: 354)

                Text("Icons on dark").font(.headline)
                iconGrid.padding().background(SkyBackground(condition: .clear, isDay: false))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .environment(\.colorScheme, .dark)
                Text("Icons on light").font(.headline)
                iconGrid.padding().background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .environment(\.colorScheme, .light)

                Text("Range bars").font(.headline)
                VStack(spacing: 14) {
                    TemperatureRangeBar(low: -18, high: -6, weekLow: -20, weekHigh: 35)
                    TemperatureRangeBar(low: -2, high: 8, weekLow: -20, weekHigh: 35, current: 4)
                    TemperatureRangeBar(low: 12, high: 24, weekLow: -20, weekHigh: 35)
                    TemperatureRangeBar(low: 22, high: 34, weekLow: -20, weekHigh: 35)
                }
                .padding()
                .background(SkyBackground(condition: .partlyCloudy, isDay: true))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding()
        }
    }

    /// A mock Lock Screen with the inline, circular and rectangular widgets, drawn white the way
    /// iOS tints them over a wallpaper.
    private var lockScreen: some View {
        let clear = lockEntry(.clear, isDay: true, temp: 7, feels: 5, place: "Milton")
        let alert = lockEntry(.thunderstorm, isDay: true, temp: 24, feels: 29, place: "Milton",
                              alert: "Severe thunderstorm warning")
        let snow = lockEntry(.snow, isDay: false, temp: -12, feels: -21, place: "Campbellville")
        let rain = lockEntry(.rainShowers, isDay: true, temp: 3, feels: -1, place: "Toronto")
        return VStack(spacing: 14) {
            VStack(spacing: 2) {
                KhanWeatherWidgetView(entry: clear, family: .accessoryInline)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: 260, height: 22)
                Text("7:45")
                    .font(.system(size: 88, weight: .bold, design: .rounded))
            }
            HStack(spacing: 10) {
                lockWidget(clear, .accessoryRectangular).frame(width: 170, height: 72)
                lockWidget(clear, .accessoryCircular).frame(width: 72, height: 72)
                lockWidget(snow, .accessoryCircular).frame(width: 72, height: 72)
            }
            HStack(spacing: 10) {
                lockWidget(alert, .accessoryRectangular).frame(width: 170, height: 72)
                lockWidget(snow, .accessoryRectangular).frame(width: 170, height: 72)
            }
            HStack(spacing: 10) {
                lockWidget(rain, .accessoryRectangular).frame(width: 170, height: 72)
                lockWidget(rain, .accessoryCircular).frame(width: 72, height: 72)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.45)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func lockWidget(_ entry: WeatherEntry, _ family: WidgetFamily) -> some View {
        KhanWeatherWidgetView(entry: entry, family: family)
    }

    private func lockEntry(_ condition: WeatherCondition, isDay: Bool, temp: Double, feels: Double,
                           place: String, alert: String? = nil) -> WeatherEntry {
        let base = WeatherEntry.placeholder
        return WeatherEntry(
            date: base.date,
            current: CurrentConditions(time: base.date, temperature: temp, feelsLike: feels,
                                       feelsLikeKind: .apparent, condition: condition, isDay: isDay),
            high: temp + 4, low: temp - 5, placeName: place, error: nil, alert: alert,
            hours: base.hours, days: base.days)
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
            ForEach(WeatherCondition.allCases, id: \.self) { c in
                ConditionIcon(condition: c, isDay: true).font(.title)
            }
            ForEach([WeatherCondition.clear, .mainlyClear, .partlyCloudy], id: \.self) { c in
                ConditionIcon(condition: c, isDay: false).font(.title)
            }
        }
    }

    private func widget(_ condition: WeatherCondition, isDay: Bool, family: WidgetFamily) -> some View {
        var entry = WeatherEntry.placeholder
        let base = entry.current!
        entry = WeatherEntry(
            date: entry.date,
            current: CurrentConditions(time: base.time, temperature: condition == .snow ? -4 : 6,
                                       feelsLike: condition == .snow ? -9 : 3, feelsLikeKind: .apparent,
                                       condition: condition, isDay: isDay),
            high: entry.high, low: entry.low, placeName: "Milton", error: nil,
            alert: condition == .thunderstorm ? "Severe thunderstorm warning" : nil,
            hours: entry.hours, days: entry.days)
        return KhanWeatherWidgetView(entry: entry, family: family)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WidgetSky(entry: entry))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
