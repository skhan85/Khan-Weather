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
    private enum CurveMode: String, CaseIterable { case temp = "Temp", rain = "Rain", wind = "Wind" }
    @State private var mode: CurveMode = .temp
    @State private var selectedIndex: Int?

    private var low: Double { hours.map { min($0.temperature, $0.modelLow ?? $0.temperature) }.min() ?? 0 }
    private var high: Double { hours.map { max($0.temperature, $0.modelHigh ?? $0.temperature) }.max() ?? 0 }
    private var hasBand: Bool { hours.contains { $0.modelLow != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(CurveMode.allCases, id: \.self) { m in
                    Button { mode = m; selectedIndex = nil } label: {
                        Text(m.rawValue)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .foregroundStyle(mode == m ? Color.black : Color.white.opacity(0.85))
                            .background(Capsule().fill(mode == m ? Brand.gold : Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                        NavigationLink {
                            HourDetailView(hour: hour, timeZone: timeZone)
                        } label: {
                            VStack(spacing: 8) {
                                timeLabel(index: index, hour: hour)
                                IconBadge(condition: hour.condition, isDay: hour.isDay, size: 38, mixed: hour.isMixedPrecipitation)
                            }
                            .frame(width: columnWidth)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Group {
                    switch mode {
                    case .temp:
                        ZStack {
                            if hasBand { band }
                            curve
                        }
                    case .rain:
                        rainStrip
                    case .wind:
                        windStrip
                    }
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
            if let rain = hour.rain, rain >= 0.05 {
                Text(WeatherFormat.rainAmount(rain))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let snow = hour.snowfall, snow >= 0.05 {
                Text(WeatherFormat.snowAmount(snow))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
        }

    private var rainStrip: some View {
        let maxWater = max(hours.map { max($0.precipitation ?? 0, ($0.snowfall ?? 0) * 0.7) }.max() ?? 0, 2.0)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(hours) { h in
                let snow = h.snowfall ?? 0
                let rain = h.rain ?? 0
                let mm = h.precipitation ?? 0
                let water = max(mm, snow * 0.7)
                let pop = h.precipitationProbability ?? 0
                let isSnowOnly = snow >= 0.1 && rain < 0.1
                let isMixed = h.isMixedPrecipitation
                let hasAmount = water >= 0.1 || snow >= 0.1
                let frac = hasAmount ? min(1.0, water / maxWater) : (pop >= 20 ? 0.12 : 0.0)
                let label: String = {
                    if isSnowOnly {
                        return UnitSettings.current.precipitation == .inches
                            ? String(format: "%.1f\"", max(0.1, snow / 2.54))
                            : String(format: "%.1f cm", snow)
                    }
                    if hasAmount {
                        return UnitSettings.current.precipitation == .inches
                            ? String(format: "%.1f\"", max(0.1, mm / 25.4))
                            : String(format: "%.1f", mm)
                    }
                    return pop >= 10 ? "\(Int(pop.rounded()))%" : "–"
                }()
                let barColor: Color = {
                    if frac <= 0 { return Color.white.opacity(0.18) }
                    if isSnowOnly { return .white }
                    if isMixed { return Color(red: 0.78, green: 0.72, blue: 1.0) }
                    return Color(red: 0.24, green: 0.91, blue: 1.0)
                }()
                let textColor: Color = {
                    if !(hasAmount || pop >= 20) { return .white.opacity(0.55) }
                    if isSnowOnly { return .white }
                    if isMixed { return Color(red: 0.78, green: 0.72, blue: 1.0) }
                    return Color(red: 0.24, green: 0.91, blue: 1.0)
                }()
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor)
                        .frame(width: 18, height: max(3, CGFloat(frac) * 46))
                }
                .frame(width: columnWidth, height: 74, alignment: .bottom)
            }
        }
    }

    private var windStrip: some View {
        let maxW = max(hours.compactMap(\.windSpeed).max() ?? 0, 25.0)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(hours) { h in
                let w = h.windSpeed ?? 0
                let g = h.windGusts ?? 0
                let frac = min(1.0, w / maxW)
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(WeatherFormat.wind(w))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(g >= 50 ? Color.orange : Brand.gold)
                        .frame(width: 18, height: max(4, CGFloat(frac) * 44))
                }
                .frame(width: columnWidth, height: 74, alignment: .bottom)
            }
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
