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
            current: CurrentConditions(time: base.time, temperature: condition == .snow ? -4 : 21,
                                       feelsLike: condition == .snow ? -9 : 23, feelsLikeKind: .apparent,
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
