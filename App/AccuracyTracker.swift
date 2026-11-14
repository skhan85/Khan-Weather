import SwiftUI
import WeatherCore

/// Writes down tomorrow's forecast from each model, and later checks it against what
/// Environment Canada's nearest climate station recorded. Runs for the current location only.
enum AccuracyTracker {
    private static let logKey = "accuracyLog"
    private static let lastRunKey = "accuracyLastRun"
    private static let defaults = UserDefaults.standard

    static var log: AccuracyLog {
        get {
            guard let data = defaults.data(forKey: logKey),
                  let log = try? JSONDecoder().decode(AccuracyLog.self, from: data) else { return AccuracyLog() }
            return log
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: logKey) }
    }

    @MainActor
    static func update(location: Coordinate, timeZone: TimeZone, now: Date = Date()) async {
        if let last = defaults.object(forKey: lastRunKey) as? Date, now.timeIntervalSince(last) < 3 * 3600 { return }
        defaults.set(now, forKey: lastRunKey)
        var log = self.log
        let today = AccuracyLog.dayString(now, timeZone: timeZone)
        let tomorrow = AccuracyLog.dayString(now, timeZone: timeZone, offsetDays: 1)

        if !log.forecasts.contains(where: { $0.day == tomorrow }),
           let rows = try? await ModelComparisonProvider().days(at: location) {
            let next = rows.filter { AccuracyLog.dayString($0.date, timeZone: timeZone) == tomorrow }
            var highs: [String: Double] = [:], lows: [String: Double] = [:]
            for row in next {
                if let h = row.high { highs[row.model.rawValue] = h }
                if let l = row.low { lows[row.model.rawValue] = l }
            }
            if !highs.isEmpty { log.record(AccuracyLog.Forecast(day: tomorrow, highs: highs, lows: lows)) }
        }

        // Climate stations post a day's record the next morning or so; try the three oldest open days.
        for day in log.unscoredDays(before: today).suffix(3) {
            if let seen = try? await ClimateDailyProvider().observed(day: day, near: location) {
                log.record(seen)
            }
        }
        self.log = log
    }
}

/// How close each model's day-ahead high and low have been to what was recorded.
struct AccuracyView: View {
    @State private var log = AccuracyTracker.log

    var body: some View {
        let scores = log.scores()
        List {
            Section {
                if scores.isEmpty {
                    Text("Khan Weather writes down tomorrow's forecast from every model each day, then checks it against Environment Canada's nearest climate station once the day's record is posted. Results show here after the first day is checked, usually within two days.")
                        .font(.subheadline.weight(.medium))
                } else {
                    ForEach(Array(scores.enumerated()), id: \.element.id) { rank, score in
                        HStack(spacing: 12) {
                            Text("\(rank + 1)")
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(rank == 0 ? Brand.gold : .white.opacity(0.7))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(score.model.name).font(.subheadline.weight(.bold))
                                Text("\(score.days) day\(score.days == 1 ? "" : "s") checked")
                                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("High ±\(error(score.highError))").font(.caption.weight(.semibold))
                                Text("Low ±\(error(score.lowError))").font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            } header: {
                SkySectionHeader(title: "Average miss, day-ahead", systemImage: "target")
            } footer: {
                Text(footer).foregroundStyle(.white.opacity(0.8))
            }
            .glassRow()
        }
        .fontDesign(.rounded)
        .foregroundStyle(.white)
        .skyBackground(.partlyCloudy, isDay: true)
        .navigationTitle("Forecast accuracy")
        .skyTitle("Forecast accuracy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { log = AccuracyTracker.log }
    }

    private var footer: String {
        let station = log.observed.last.map { " Checked against \($0.station)." } ?? ""
        return "Tracks your current location over the last \(AccuracyLog.keepDays) days.\(station) Smaller is better."
    }

    /// An error in the user's temperature unit, one decimal.
    private func error(_ celsius: Double) -> String {
        let fahrenheit = UnitSettings.current.temperature != .celsius
        let value = fahrenheit ? celsius * 9 / 5 : celsius
        return String(format: "%.1f°", value)
    }
}
