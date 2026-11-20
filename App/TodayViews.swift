import SwiftUI
import WeatherCore

/// Morning, afternoon, evening and overnight: icon, temperature, feels-like and chance of rain.
/// Built from the same hours as the hourly curve (`Forecast.dayParts`).
struct DayPartsView: View {
    let parts: [DayPart]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(parts) { part in
                VStack(spacing: 4) {
                    Text(part.kind.label)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    IconBadge(condition: part.condition, isDay: part.isDay, size: 38)
                    Text(WeatherFormat.temperature(part.temperature))
                        .font(.title2.weight(.bold))
                    if let feels = part.feelsLike {
                        Text("Feels \(WeatherFormat.temperature(feels))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    PrecipChance(probability: part.precipitationProbability, kind: part.precipitationKind,
                                 font: .caption2.weight(.semibold), showsIcon: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 4)
    }
}

/// The sun's path from sunrise to sunset, with the sun where it is now.
struct SunArcView: View {
    let sunrise: Date
    let sunset: Date
    let timeZone: TimeZone
    /// Fixed time for previews; nil follows the clock.
    var now: Date? = nil

    var body: some View {
        if let now {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in content(context.date) }
        }
    }

    private func progress(_ date: Date) -> Double {
        let span = sunset.timeIntervalSince(sunrise)
        guard span > 0 else { return 0 }
        return min(max(date.timeIntervalSince(sunrise) / span, 0), 1)
    }

    private func caption(_ date: Date) -> String {
        if date < sunrise { return "Sunrise in \(Self.duration(sunrise.timeIntervalSince(date)))" }
        if date < sunset { return "Sunset in \(Self.duration(sunset.timeIntervalSince(date)))" }
        return "The sun has set"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let mins = max(Int(seconds / 60), 1)
        if mins < 60 { return "\(mins) min" }
        return mins % 60 == 0 ? "\(mins / 60) hr" : "\(mins / 60) hr \(mins % 60) min"
    }

    private func content(_ date: Date) -> some View {
        let t = progress(date)
        let up = date >= sunrise && date < sunset
        return VStack(spacing: 6) {
            Canvas { ctx, size in
                let base = size.height - 8
                let w = size.width - 24
                let h = base - 14
                func point(_ p: Double) -> CGPoint {
                    CGPoint(x: 12 + p * w, y: base - sin(p * .pi) * h)
                }
                var arc = Path()
                arc.move(to: point(0))
                for i in 1...60 { arc.addLine(to: point(Double(i) / 60)) }
                ctx.stroke(arc, with: .color(.white.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                if t > 0 {
                    var done = Path()
                    done.move(to: point(0))
                    let steps = max(Int(t * 60), 1)
                    for i in 1...steps { done.addLine(to: point(t * Double(i) / Double(steps))) }
                    ctx.stroke(done, with: .color(Brand.gold), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                var horizon = Path()
                horizon.move(to: CGPoint(x: 0, y: base))
                horizon.addLine(to: CGPoint(x: size.width, y: base))
                ctx.stroke(horizon, with: .color(.white.opacity(0.5)), lineWidth: 1)
                let sun = point(t)
                let r: CGFloat = 9
                let disc = Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: 2 * r, height: 2 * r))
                if up {
                    ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 2 * r, y: sun.y - 2 * r, width: 4 * r, height: 4 * r)),
                             with: .color(Brand.gold.opacity(0.25)))
                    ctx.fill(disc, with: .color(Brand.gold))
                } else {
                    ctx.fill(disc, with: .color(.white.opacity(0.35)))
                }
            }
            .frame(height: 86)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Sunrise", systemImage: "sunrise.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(TimeText.time(sunrise, timeZone)).font(.body.weight(.semibold))
                }
                Spacer(minLength: 6)
                Text(caption(date))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.gold)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Label("Sunset", systemImage: "sunset.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(TimeText.time(sunset, timeZone)).font(.body.weight(.semibold))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Next two hours in 15-minute bars, under the same "Rain starting in about 20 min" line the
/// Now card and the notification use (both read `Forecast.nowcastSlots`).
struct NextTwoHoursView: View {
    let nowcast: Nowcast
    let slots: [PrecipitationSlot]

    /// mm per 15 minutes at which a bar is full height (about 4 mm/h, heavy rain).
    private static let full = 1.0

    private func height(_ s: PrecipitationSlot) -> CGFloat {
        guard s.isWet else { return 3 }
        let amount = max(s.precipitation, s.snowfall)
        // Square root so drizzle still shows and a downpour doesn't flatten everything else.
        return 10 + 50 * CGFloat(min(sqrt(amount / Self.full), 1))
    }

    private func color(_ s: PrecipitationSlot) -> Color {
        guard s.isWet else { return .white.opacity(0.3) }
        if s.snowfall > 0 && s.rain < PrecipitationSlot.wetThreshold { return .white }
        if s.snowfall > 0 { return Color(red: 0.78, green: 0.72, blue: 1) }
        return Color(red: 0.45, green: 0.75, blue: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(nowcast.text).font(.headline)
            } icon: {
                Image(systemName: nowcast.kind == .snow ? "cloud.snow.fill" : "cloud.rain.fill")
                    .foregroundStyle(Brand.gold)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(slots, id: \.time) { s in
                    Capsule()
                        .fill(color(s))
                        .frame(maxWidth: .infinity)
                        .frame(height: height(s))
                }
            }
            .frame(height: 62, alignment: .bottom)
            HStack {
                Text("Now")
                Spacer()
                Text("1 hr")
                Spacer()
                Text("2 hr")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.82))
            Text("Light to heavy, in 15-minute steps.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nowcast.text)
    }
}

/// Tonight's moon under the sun arc: phase icon, name, how much is lit and the next full moon.
struct MoonRow: View {
    let date: Date
    let timeZone: TimeZone

    var body: some View {
        let moon = MoonPhase(date: date)
        let full = moon.nextFullMoon(after: date)
        HStack(spacing: 10) {
            Image(systemName: moon.symbolName)
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(moon.name).font(.body.weight(.semibold))
                Text("\(Int((moon.illumination * 100).rounded()))% lit")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.82))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Full moon").font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.82))
                Text(full.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.body.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
