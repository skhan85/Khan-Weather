import SwiftUI
import WeatherCore

/// The main screen's air quality card: AQI in a round badge, a colour scale, advice, and pollen.
struct AirQualityView: View {
    let air: AirQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let aqi = air.usAQI, let category = air.category {
                HStack(spacing: 14) {
                    Text("\(Int(aqi.rounded()))")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(.white.opacity(0.14)))
                        .overlay(Circle().stroke(AQIColor.color(category), lineWidth: 4))
                        .accessibilityLabel("Air quality index \(Int(aqi.rounded()))")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.label)
                            .font(.headline)
                        if let peak = air.todayMaxAQI, peak.rounded() > aqi.rounded() + 4 {
                            Text("Up to \(Int(peak.rounded())) later today")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.82))
                        }
                    }
                }
                AQIScale(aqi: aqi)
                Text(category.advice)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let v = air.pm25 { FactChip(text: "PM2.5 \(Self.number(v))", systemImage: "aqi.low") }
                    if let v = air.pm10 { FactChip(text: "PM10 \(Self.number(v))", systemImage: "aqi.low") }
                    if let v = air.ozone { FactChip(text: "Ozone \(Self.number(v))", systemImage: "sun.haze") }
                    if let v = air.nitrogenDioxide { FactChip(text: "NO₂ \(Self.number(v))", systemImage: "car") }
                }
            }

            if !air.pollen.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Pollen", systemImage: "leaf.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    ForEach(air.pollen.prefix(4)) { p in
                        HStack {
                            Text(p.kind.label)
                            Spacer()
                            PollenLevelDots(level: p.level)
                            Text(p.level.label)
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 80, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if air.hasPollenData {
                Label("No pollen in the air today", systemImage: "leaf")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.82))
            }

            Text(air.hasPollenData
                 ? "US AQI and pollen from Open-Meteo (Copernicus CAMS). Pollutants in µg/m³."
                 : "US AQI from Open-Meteo (Copernicus CAMS). Pollutants in µg/m³. Pollen forecasts cover Europe only.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.vertical, 4)
        .fontDesign(.rounded)
    }

    private static func number(_ v: Double) -> String { String(Int(v.rounded())) }
}

/// EPA colours, a touch softened so they sit well on the sky.
enum AQIColor {
    static func color(_ c: AQICategory) -> Color {
        switch c {
        case .good: return Color(red: 0.36, green: 0.84, blue: 0.45)
        case .moderate: return Color(red: 1.0, green: 0.86, blue: 0.30)
        case .sensitive: return Color(red: 1.0, green: 0.60, blue: 0.25)
        case .unhealthy: return Color(red: 0.96, green: 0.32, blue: 0.32)
        case .veryUnhealthy: return Color(red: 0.66, green: 0.40, blue: 0.86)
        case .hazardous: return Color(red: 0.62, green: 0.20, blue: 0.30)
        }
    }
}

/// A bar from 0 to 300 in the EPA colours, with a dot at the current value.
private struct AQIScale: View {
    let aqi: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = min(max(aqi / 300, 0), 1) * w
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(
                    stops: [
                        .init(color: AQIColor.color(.good), location: 0),
                        .init(color: AQIColor.color(.good), location: 0.15),
                        .init(color: AQIColor.color(.moderate), location: 0.25),
                        .init(color: AQIColor.color(.sensitive), location: 0.42),
                        .init(color: AQIColor.color(.unhealthy), location: 0.58),
                        .init(color: AQIColor.color(.veryUnhealthy), location: 0.8),
                        .init(color: AQIColor.color(.hazardous), location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
                    .frame(width: geo.size.height + 4, height: geo.size.height + 4)
                    .offset(x: x - (geo.size.height + 4) / 2)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// Four gold dots, filled up to the level.
private struct PollenLevelDots: View {
    let level: Pollen.Level

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                Circle()
                    .fill(i <= level.rawValue ? Brand.gold : .white.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
