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
                let symbol = nowcast.kind == .snow ? "cloud.snow.fill"
                    : nowcast.kind == .mixed ? "cloud.sleet.fill" : "cloud.rain.fill"
                Image(systemName: symbol)
                    .foregroundStyle(Brand.gold)
            }
            let midTime = slots.count > 4 ? slots[slots.count / 2].time : Date().addingTimeInterval(3600)
            let endTime = slots.last?.time.addingTimeInterval(900) ?? Date().addingTimeInterval(7200)
            let tickLabel: (Date) -> String = { d in
                let f = DateFormatter()
                f.timeZone = TimeZone.current
                f.locale = Locale(identifier: "en_US_POSIX")
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone.current
                f.dateFormat = cal.component(.minute, from: d) == 0 ? "h a" : "h:mm a"
                return f.string(from: d).lowercased()
            }
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Heavy")
                    Spacer()
                    Text("Moderate")
                    Spacer()
                    Text("Light")
                    Spacer().frame(height: 12)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 48, height: 92)

                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle().fill(.white.opacity(0.14)).frame(height: 0.75)
                        Spacer()
                        Rectangle().fill(.white.opacity(0.14)).frame(height: 0.75)
                        Spacer()
                        Rectangle().fill(.white.opacity(0.14)).frame(height: 0.75)
                        Spacer()
                        Rectangle().fill(.white.opacity(0.24)).frame(height: 1)
                    }
                    .frame(height: 92)

                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(slots, id: \.time) { s in
                            let h: CGFloat = s.isWet
                                ? 14 + 74 * CGFloat(s.intensity)
                                : 3
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(color(s))
                                .frame(maxWidth: .infinity)
                                .frame(height: h)
                        }
                    }
                    .frame(height: 92, alignment: .bottom)
                }
            }
            HStack {
                Text("Now")
                Spacer()
                Text(tickLabel(midTime))
                Spacer()
                Text(tickLabel(endTime))
            }
            .padding(.leading, 56)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.84))
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Capsule().fill(Color(red: 0.45, green: 0.75, blue: 1.0)).frame(width: 14, height: 6)
                    Text("Rain")
                }
                HStack(spacing: 5) {
                    Capsule().fill(.white).frame(width: 14, height: 6)
                    Text("Snow")
                }
                HStack(spacing: 5) {
                    Capsule().fill(Color(red: 0.78, green: 0.72, blue: 1.0)).frame(width: 14, height: 6)
                    Text("Mixed")
                }
            }
            .padding(.leading, 56)
            .padding(.top, 2)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
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


// MARK: - Weekend Forecast Screen (Weather Network style)

struct WeekendView: View {
    let forecast: Forecast
    @State private var tab: Int = 0
    @State private var expandedDayID: Date? = nil

    private struct PartSummary: Identifiable {
        let id: String
        let label: String
        let condition: WeatherCondition
        let isDay: Bool
        let temp: Double
        let feelsLike: Double
        let pop: Double
        let precipMm: Double
        let isSnow: Bool
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = forecast.timeZone
        return c
    }

    /// Groups Fri (6), Sat (7), Sun (1) into [thisWeekend, nextWeekend].
    private var weekends: [[DailyForecast]] {
        let days = forecast.displayDaily()
        var buckets: [[DailyForecast]] = []
        var current: [DailyForecast] = []
        for d in days {
            let wd = cal.component(.weekday, from: d.date)
            if wd == 6 || wd == 7 || wd == 1 {
                if wd == 6 && !current.isEmpty {
                    buckets.append(current)
                    current = []
                }
                current.append(d)
                if wd == 1 {
                    buckets.append(current)
                    current = []
                }
            } else if !current.isEmpty {
                buckets.append(current)
                current = []
            }
        }
        if !current.isEmpty { buckets.append(current) }
        return buckets
    }

    private var activeDays: [DailyForecast] {
        guard !weekends.isEmpty else { return [] }
        return tab < weekends.count ? weekends[tab] : []
    }

    private func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = forecast.timeZone
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = forecast.timeZone
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func summaryText(for days: [DailyForecast]) -> String {
        guard !days.isEmpty else {
            return "Next weekend is just beyond the current 10-day forecast window."
        }
        let parts = days.map { d -> String in
            let name = dayName(d.date)
            let cond = d.condition.description.lowercased()
            let hi = WeatherFormat.temperature(d.high)
            let pop = Int((d.precipitationProbability ?? 0).rounded())
            if d.condition.isPrecipitation || pop >= 50 {
                return "\(name) looks wet (\(cond), high \(hi), \(pop)% chance)"
            }
            return "\(name) brings \(cond) skies near \(hi)"
        }
        if parts.count == 1 { return parts[0] + "." }
        if parts.count == 2 { return parts[0] + ", while " + parts[1] + "." }
        return parts[0] + ". " + parts[1] + ", and " + parts[2] + "."
    }

    private func parts(for day: DailyForecast) -> [PartSummary] {
        let hrs = forecast.hours(on: day)
        guard !hrs.isEmpty else { return [] }
        let slices: [(String, ClosedRange<Int>, Bool)] = [
            ("Morn", 6...11, true),
            ("Aft", 12...17, true),
            ("Eve", 18...23, false),
            ("Night", 0...5, false)
        ]
        return slices.compactMap { label, range, isDay in
            let sub = hrs.filter { range.contains(cal.component(.hour, from: $0.time)) }
            guard !sub.isEmpty else { return nil }
            let temps = sub.map(\.temperature)
            let feels = sub.map { $0.feelsLike ?? $0.temperature }
            let temp = isDay ? (temps.max() ?? temps[0]) : (temps.min() ?? temps[0])
            let feel = isDay ? (feels.max() ?? feels[0]) : (feels.min() ?? feels[0])
            let pop = sub.compactMap(\.precipitationProbability).max() ?? 0
            let rainSum = sub.reduce(0.0) { $0 + ($1.rain ?? 0) }
            let snowSum = sub.reduce(0.0) { $0 + ($1.snowfall ?? 0) }
            let precipSum = max(sub.reduce(0.0) { $0 + ($1.precipitation ?? 0) }, rainSum + snowSum * 0.7)
            let isSnow = snowSum > rainSum && snowSum >= 0.1
            // Pick wettest / most notable condition in the slice
            var cond = sub.first(where: { $0.condition.isWetOrStorm })?.condition ?? sub[sub.count / 2].condition
            if !cond.isWetOrStorm && pop >= 50 {
                cond = isSnow ? .snow : .rain
            }
            return PartSummary(id: label, label: label, condition: cond, isDay: isDay,
                               temp: temp, feelsLike: feel, pop: pop, precipMm: precipSum, isSnow: isSnow)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Segmented toggle: This weekend | Next weekend
                HStack(spacing: 4) {
                    ForEach([(0, "This weekend"), (1, "Next weekend")], id: \.0) { idx, title in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                tab = idx
                                expandedDayID = weekends.indices.contains(idx) ? weekends[idx].first?.date : nil
                            }
                        } label: {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(tab == idx ? Color(red: 1.0, green: 0.85, blue: 0.28) : .white.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule().fill(tab == idx ? .white.opacity(0.16) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Capsule().fill(.white.opacity(0.08)))

                // Weekend summary card
                Text(summaryText(for: activeDays))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.10)))

                // Weekend day cards
                if !activeDays.isEmpty {
                    VStack(spacing: 10) {
                        HStack {
                            Label("Weekend Forecast", systemImage: "calendar")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.bottom, 2)

                        ForEach(activeDays) { day in
                            let isExpanded = (expandedDayID ?? activeDays.first?.date) == day.date
                            let dayParts = parts(for: day)
                            let totalMm = (day.rainSum ?? 0) + (day.snowfallSum ?? 0)
                            let pop = Int((day.precipitationProbability ?? 0).rounded())

                            VStack(spacing: 0) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedDayID = isExpanded ? Date.distantPast : day.date
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(dayName(day.date))
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Text(monthDay(day.date))
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.68))
                                        }
                                        .frame(width: 54, alignment: .leading)

                                        IconBadge(condition: day.condition, isDay: true, size: 32)
                                        Text(WeatherFormat.temperature(day.high))
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.white)
                                        Text(WeatherFormat.temperature(day.low))
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.68))

                                        Spacer()

                                        VStack(alignment: .trailing, spacing: 2) {
                                            if pop >= 20 {
                                                Text("\(pop)%")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(Color(red: 0.45, green: 0.80, blue: 1.0))
                                            }
                                            if totalMm >= 0.5 {
                                                Text(String(format: "%.0f mm", totalMm))
                                                    .font(.caption2)
                                                    .foregroundStyle(.white.opacity(0.75))
                                            }
                                        }
                                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    .padding(12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if isExpanded {
                                    if !dayParts.isEmpty {
                                        let maxMm = max(dayParts.map(\.precipMm).max() ?? 1.0, 2.0)
                                        HStack(spacing: 1) {
                                            ForEach(dayParts) { part in
                                                let fillFrac = min(1.0, part.precipMm / maxMm)
                                                VStack(spacing: 6) {
                                                    Text(part.label)
                                                        .font(.caption.weight(.medium))
                                                        .foregroundStyle(.white.opacity(0.75))
                                                    IconBadge(condition: part.condition, isDay: part.isDay, size: 32)
                                                    Text(WeatherFormat.temperature(part.temp))
                                                        .font(.title3.weight(.bold))
                                                        .foregroundStyle(.white)
                                                    Text("Feels \(WeatherFormat.temperature(part.feelsLike))")
                                                        .font(.caption2)
                                                        .foregroundStyle(.white.opacity(0.68))
                                                    if part.pop >= 15 {
                                                        Text("\(Int(part.pop.rounded()))%")
                                                            .font(.caption2.weight(.semibold))
                                                            .foregroundStyle(Color(red: 0.45, green: 0.80, blue: 1.0))
                                                    } else {
                                                        Text("–").font(.caption2).foregroundStyle(.white.opacity(0.4))
                                                    }
                                                    Text(part.precipMm >= 0.1 ? String(format: "%.1f mm", part.precipMm) : "–")
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.white.opacity(0.75))
                                                    ZStack(alignment: .bottom) {
                                                        Color.clear.frame(height: 22)
                                                        if part.precipMm >= 0.1 {
                                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                                .fill((part.isSnow ? Color.white : Color(red: 0.35, green: 0.72, blue: 1.0)).opacity(0.45))
                                                                .frame(height: max(5, 22 * CGFloat(fillFrac)))
                                                        }
                                                    }
                                                }
                                                .frame(maxWidth: .infinity)
                                                .padding(.top, 10)
                                                .background(part.isDay ? .white.opacity(0.05) : .black.opacity(0.14))
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .padding([.horizontal, .bottom], 8)
                                    } else {
                                        Text("\(day.condition.description) · High \(WeatherFormat.temperature(day.high)), Low \(WeatherFormat.temperature(day.low))")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.75))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding([.horizontal, .bottom], 12)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08)))
                }
            }
            .padding(16)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.15, blue: 0.28), Color(red: 0.05, green: 0.09, blue: 0.18)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
        )
        .navigationTitle("Weekend")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if expandedDayID == nil { expandedDayID = activeDays.first?.date }
        }
    }
}
