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

    private var usedModel: WeatherModel { .usedForTemperatures(at: location) }

    var body: some View {
        List {
            if loading {
                ProgressView("Asking each model…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .glassRow()
            } else if failed {
                ContentUnavailableView("Couldn't load the models", systemImage: "exclamationmark.triangle",
                                       description: Text("Check your connection and try again."))
                    .glassRow()
            } else {
                if let summary = agreement {
                    Section {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Brand.gold).frame(width: 4)
                            Text(summary)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(.rounded)
                        }
                        .padding(.vertical, 4)
                    }
                    .glassRow()
                }
                Section {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            IconBadge(condition: row.condition, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.model.name)
                                    .font(.subheadline.weight(row.model == usedModel ? .bold : .semibold))
                                if row.model == usedModel {
                                    Text("Used by Khan Weather")
                                        .font(.caption2.weight(.heavy))
                                        .foregroundStyle(.black.opacity(0.8))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Brand.gold))
                                }
                                if let totals = WeatherFormat.precipitationTotals(rainMm: row.rainMm, snowCm: row.snowCm) {
                                    Text(totals).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                                }
                            }
                            Spacer(minLength: 4)
                            Text(WeatherFormat.temperature(row.low))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(WeatherFormat.temperature(row.high))
                                .font(.body.weight(.bold))
                                .frame(width: 40, alignment: .trailing)
                        }
                        .fontDesign(.rounded)
                    }
                } header: {
                    SkySectionHeader(title: "Low and high by model", systemImage: "chart.bar.xaxis")
                } footer: {
                    Text(footer)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .glassRow()
            }
        }
        .foregroundStyle(.white)
        .skyBackground(day.condition, isDay: true)
        .navigationTitle("Compare models")
        .skyTitle("Compare models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var footer: String {
        let source = usedModel == .blend
            ? "Khan Weather's temperatures are a weighted blend: the high-res Canadian and US models count most for the next two days, then the European model leads. The first hours are also eased toward nearby station readings."
            : "Khan Weather's temperatures here come from \(usedModel.name)."
        return source + " High-res models only reach a day or two ahead. Models via Open-Meteo.com (CC BY 4.0)."
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
            let sameDay = try await ModelComparisonProvider().days(at: location)
                .filter { calendar.isDate($0.date, inSameDayAs: day.date) }
            let used = usedModel
            rows = sameDay.filter { $0.model == used } + sameDay.filter { $0.model != used }
            failed = rows.isEmpty
        } catch {
            failed = true
        }
    }
}
