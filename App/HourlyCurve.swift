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
    @State private var selectedIndex: Int?

    private var low: Double { hours.map { min($0.temperature, $0.modelLow ?? $0.temperature) }.min() ?? 0 }
    private var high: Double { hours.map { max($0.temperature, $0.modelHigh ?? $0.temperature) }.max() ?? 0 }
    private var hasBand: Bool { hours.contains { $0.modelLow != nil } }

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
                ZStack {
                    if hasBand { band }
                    curve
                }
                .frame(width: columnWidth * CGFloat(hours.count), height: 74)
                .contentShape(Rectangle())
                // Touch and hold, then slide, to read each hour. A plain swipe still scrolls the strip.
                .gesture(
                    LongPressGesture(minimumDuration: 0.25)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            if case .second(true, let drag?) = value { select(at: drag.location.x) }
                        }
                        .onEnded { _ in selectedIndex = nil }
                )
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
        // Over the strip rather than above it, so the chart doesn't jump under the finger.
        .overlay(alignment: .top) {
            if let idx = selectedIndex, hours.indices.contains(idx) {
                scrubBanner(for: hours[idx])
                    .allowsHitTesting(false)
            }
        }
    }

    private func select(at x: CGFloat) {
        let idx = Int(x / columnWidth)
        if hours.indices.contains(idx) { selectedIndex = idx }
    }

    private func scrubBanner(for hour: HourlyForecast) -> some View {
        HStack(spacing: 10) {
            Text(TimeText.hour(hour.time, timeZone))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.gold)
            Text(WeatherFormat.temperature(hour.temperature))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
            if let feelsLike = hour.feelsLike {
                Text("Feels \(WeatherFormat.temperature(feelsLike))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let wind = hour.windSpeed {
                Text(WeatherFormat.wind(wind))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let rain = hour.rain {
                Text(String(format: "%.1f mm", rain))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
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

    private var span: Double { max(high - low, 4) }
    private var floor: Double { low - span * 0.6 }

    /// Where the models spread: the faint band behind the line. Wider means less sure.
    private var band: some View {
        Chart {
            ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                if let lo = hour.modelLow, let hi = hour.modelHigh {
                    AreaMark(x: .value("Hour", Double(index)), yStart: .value("Low", lo), yEnd: .value("High", hi))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.white.opacity(0.16))
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

    private var curve: some View {
        // Leave room above the line for the numbers and below it for the shaded area.
        let span = self.span
        let floor = self.floor
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
                    .symbolSize(selectedIndex == index ? 80 : (index == 0 ? 60 : 28))
                    .foregroundStyle(selectedIndex == index ? Brand.gold : .white)
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
