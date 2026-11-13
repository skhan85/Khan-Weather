import SwiftUI
import WeatherCore

/// One day as several weather models see it. Close agreement means a surer forecast.
struct ModelComparisonView: View {
    let day: DailyForecast
    let location: Coordinate
    let timeZone: TimeZone

    @State private var rows: [ModelDay] = []
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView("Asking each model…")
                    .frame(maxWidth: .infinity)
            } else if failed {
                ContentUnavailableView("Couldn't load the models", systemImage: "exclamationmark.triangle",
                                       description: Text("Check your connection and try again."))
            } else {
                if let summary = agreement {
                    Section { Text(summary).font(.subheadline) }
                }
                Section {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            ConditionIcon(condition: row.condition)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.model.name)
                                    .font(.subheadline.weight(row.model == .bestMatch ? .semibold : .regular))
                                if let totals = WeatherFormat.precipitationTotals(rainMm: row.rainMm, snowCm: row.snowCm) {
                                    Text(totals).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(WeatherFormat.temperature(row.low)).foregroundStyle(.secondary)
                            Text(WeatherFormat.temperature(row.high)).frame(width: 40, alignment: .trailing)
                        }
                    }
                } footer: {
                    Text("Khan Weather uses the best match, which picks the sharpest local model for your spot. Models via Open-Meteo.com (CC BY 4.0).")
                }
            }
        }
        .navigationTitle("Compare models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// "Models agree within 2°" or "Models disagree: highs from 3° to 9°".
    private var agreement: String? {
        let highs = rows.compactMap(\.high)
        guard highs.count >= 2, let lo = highs.min(), let hi = highs.max() else { return nil }
        let unit = UnitSettings.current.temperature
        let spread = Int((unit.convert(hi) - unit.convert(lo)).rounded())
        if spread <= 2 { return "The models agree on the high within \(spread)°. This forecast is fairly sure." }
        return "The models differ on the high, from \(WeatherFormat.temperature(lo)) to \(WeatherFormat.temperature(hi)). Treat this day as less certain."
    }

    private func load() async {
        defer { loading = false }
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            rows = try await ModelComparisonProvider().days(at: location)
                .filter { calendar.isDate($0.date, inSameDayAs: day.date) }
            failed = rows.isEmpty
        } catch {
            failed = true
        }
    }
}
