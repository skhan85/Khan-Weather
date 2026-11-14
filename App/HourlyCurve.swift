import Charts
import SwiftUI
import WeatherCore

/// The next hours as a scrolling strip: time and icon on top, a temperature curve with the
/// numbers on it, and the chance of rain or snow underneath. Tap a column for that hour.
struct HourlyCurve: View {
    let hours: [HourlyForecast]
    let timeZone: TimeZone
    /// Label the first column "Now" (off for a future day's hours).
    var firstIsNow = true

    private let columnWidth: CGFloat = 58

    private var low: Double { hours.map(\.temperature).min() ?? 0 }
    private var high: Double { hours.map(\.temperature).max() ?? 0 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                        NavigationLink {
                            HourDetailView(hour: hour, timeZone: timeZone)
                        } label: {
                            VStack(spacing: 8) {
                                timeLabel(index: index, hour: hour)
                                IconBadge(condition: hour.condition, isDay: hour.isDay, size: 38)
                            }
                            .frame(width: columnWidth)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                curve
                    .frame(width: columnWidth * CGFloat(hours.count), height: 74)
                HStack(spacing: 0) {
                    ForEach(hours) { hour in
                        PrecipChance(probability: hour.precipitationProbability, kind: hour.precipitationKind,
                                     font: .caption.weight(.semibold))
                            .frame(width: columnWidth, height: 16)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func timeLabel(index: Int, hour: HourlyForecast) -> some View {
        if index == 0 && firstIsNow {
            Text("Now")
                .font(.footnote.weight(.heavy))
                .foregroundStyle(.black.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Brand.gold))
        } else {
            Text(TimeText.hour(hour.time, timeZone))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 2)
        }
    }

    private var curve: some View {
        // Leave room above the line for the numbers and below it for the shaded area.
        let span = max(high - low, 4)
        let floor = low - span * 0.6
        return Chart {
            ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                AreaMark(x: .value("Hour", Double(index)), yStart: .value("Base", floor), yEnd: .value("Temp", hour.temperature))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Brand.gold.opacity(0.35), Brand.gold.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Hour", Double(index)), y: .value("Temp", hour.temperature))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .foregroundStyle(Brand.gold)
                PointMark(x: .value("Hour", Double(index)), y: .value("Temp", hour.temperature))
                    .symbolSize(index == 0 ? 60 : 28)
                    .foregroundStyle(.white)
                    .annotation(position: .top, spacing: 4) {
                        Text(WeatherFormat.temperature(hour.temperature))
                            .font(.subheadline.weight(.bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    }
            }
        }
        .chartXScale(domain: -0.5 ... Double(hours.count) - 0.5)
        .chartYScale(domain: floor ... high + span * 0.9)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}
