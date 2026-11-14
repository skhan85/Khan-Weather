import SwiftUI
import WeatherCore

/// The sky behind the forecast: a gradient that follows the weather and whether it's day or night.
/// Colours stay dark enough at the top for white text, so the screen is readable in bright sun too.
struct SkyBackground: View {
    var condition: WeatherCondition = .partlyCloudy
    var isDay: Bool = true

    var body: some View {
        let sky = Sky(condition: condition, isDay: isDay)
        ZStack {
            LinearGradient(colors: [sky.top, sky.bottom], startPoint: .top, endPoint: .bottom)
            switch sky.decoration {
            case .sunGlow:
                RadialGradient(colors: [Color(red: 1, green: 0.93, blue: 0.7).opacity(0.45), .clear],
                               center: UnitPoint(x: 0.85, y: 0.02), startRadius: 0, endRadius: 320)
            case .stars:
                StarField()
            case .haze:
                LinearGradient(colors: [.clear, .white.opacity(0.12)], startPoint: .top, endPoint: .bottom)
            case .plain:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.8), value: sky)
    }
}

/// Colour pair and extra layer for one kind of sky.
struct Sky: Equatable {
    enum Decoration: Equatable { case plain, sunGlow, stars, haze }

    let top: Color
    let bottom: Color
    let decoration: Decoration

    init(condition: WeatherCondition, isDay: Bool) {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        let v: (Color, Color, Decoration)
        switch (Self.group(condition), isDay) {
        case (.clear, true):
            v = (rgb(0.16, 0.45, 0.86), rgb(0.40, 0.68, 0.96), .sunGlow)
        case (.partly, true):
            v = (rgb(0.24, 0.47, 0.78), rgb(0.52, 0.68, 0.88), .plain)
        case (.grey, true):
            v = (rgb(0.36, 0.42, 0.50), rgb(0.56, 0.61, 0.68), .haze)
        case (.wet, true):
            v = (rgb(0.24, 0.32, 0.43), rgb(0.42, 0.50, 0.60), .plain)
        case (.snow, true):
            v = (rgb(0.38, 0.48, 0.62), rgb(0.62, 0.70, 0.80), .haze)
        case (.storm, true):
            v = (rgb(0.18, 0.18, 0.30), rgb(0.34, 0.34, 0.46), .plain)
        case (.clear, false):
            v = (rgb(0.03, 0.06, 0.18), rgb(0.12, 0.19, 0.38), .stars)
        case (.partly, false):
            v = (rgb(0.06, 0.09, 0.20), rgb(0.18, 0.23, 0.36), .stars)
        case (.grey, false), (.snow, false):
            v = (rgb(0.10, 0.12, 0.18), rgb(0.23, 0.26, 0.33), .plain)
        case (.wet, false), (.storm, false):
            v = (rgb(0.07, 0.09, 0.15), rgb(0.17, 0.20, 0.28), .plain)
        }
        top = v.0
        bottom = v.1
        decoration = v.2
    }

    private enum Group { case clear, partly, grey, wet, snow, storm }

    private static func group(_ c: WeatherCondition) -> Group {
        switch c {
        case .clear: return .clear
        case .mainlyClear, .partlyCloudy: return .partly
        case .overcast, .fog, .unknown: return .grey
        case .drizzle, .rain, .rainShowers, .freezingDrizzle, .freezingRain: return .wet
        case .snow, .snowGrains, .snowShowers: return .snow
        case .thunderstorm, .thunderstormHail: return .storm
        }
    }
}

/// A few faint, fixed stars in the top half of a clear night sky.
private struct StarField: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(1 << 31)
            }
            for _ in 0..<60 {
                let x = next() * size.width
                let y = next() * size.height * 0.5
                let r = 0.6 + next() * 1.1
                let alpha = 0.25 + next() * 0.5
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Colours for temperatures, cold violet through warm red. Takes °C.
enum TemperatureColor {
    private static let stops: [(Double, (Double, Double, Double))] = [
        (-25, (0.62, 0.50, 1.00)),
        (-10, (0.38, 0.62, 1.00)),
        (0, (0.36, 0.86, 0.96)),
        (10, (0.46, 0.88, 0.52)),
        (20, (1.00, 0.84, 0.30)),
        (30, (1.00, 0.56, 0.24)),
        (40, (0.96, 0.30, 0.30)),
    ]

    static func color(_ celsius: Double) -> Color {
        let t = min(max(celsius, stops.first!.0), stops.last!.0)
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1]
            let (t1, c1) = stops[i]
            let f = (t - t0) / (t1 - t0)
            return Color(red: c0.0 + (c1.0 - c0.0) * f,
                         green: c0.1 + (c1.1 - c0.1) * f,
                         blue: c0.2 + (c1.2 - c0.2) * f)
        }
        let c = stops.last!.1
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    /// A left-to-right gradient covering `low...high`.
    static func gradient(low: Double, high: Double) -> LinearGradient {
        let steps = 4
        let colors = (0...steps).map { color(low + (high - low) * Double($0) / Double(steps)) }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// A day's low-to-high span drawn against the whole week's range, like a thermometer lying down.
struct TemperatureRangeBar: View {
    let low: Double
    let high: Double
    let weekLow: Double
    let weekHigh: Double
    /// Shown as a dot on today's bar.
    var current: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let span = max(weekHigh - weekLow, 1)
            let w = geo.size.width
            let start = (low - weekLow) / span * w
            let end = (high - weekLow) / span * w
            let barWidth = max(end - start, geo.size.height)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(TemperatureColor.gradient(low: low, high: high))
                    .frame(width: barWidth)
                    .offset(x: min(start, w - barWidth))
                if let current {
                    let x = min(max((current - weekLow) / span * w, 0), w)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
                        .frame(width: geo.size.height + 3, height: geo.size.height + 3)
                        .offset(x: x - (geo.size.height + 3) / 2)
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Translucent "glass" row background used on the sky screens.
    func glassRow() -> some View {
        listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }

    /// The sky behind a list, with dark-style (white) text on top.
    func skyBackground(_ condition: WeatherCondition, isDay: Bool) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { SkyBackground(condition: condition, isDay: isDay).ignoresSafeArea() }
            .environment(\.colorScheme, .dark)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// Section title that reads well on the sky.
struct SkySectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
            .textCase(nil)
    }
}
