import SwiftUI
import WeatherCore

/// One day as several weather models see it. Close agreement means a surer forecast.
struct ModelComparisonView: View {
    let day: DailyForecast
    let location: Coordinate
    let timeZone: TimeZone
    /// The app's calendar-day rows (`Forecast.daily`), so Today compares midnight-to-midnight alongside the other models.
    var appDays: [DailyForecast] = []

    @State private var rows: [ModelDay] = []
    @State private var failed = false
    @State private var loading = true
    @State private var externalSources: [RelayConsensus.Source] = []

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
                if !externalSources.isEmpty {
                    Section {
                        ForEach(externalSources) { src in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(src.provider).font(.subheadline.weight(.semibold))
                                    if let cond = src.condition {
                                        Text(cond).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Now \(WeatherFormat.temperature(src.temperature))")
                                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                                    if let hi = src.high, let lo = src.low {
                                        Text("\(WeatherFormat.temperature(hi)) / \(WeatherFormat.temperature(lo))")
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                        }
                    } header: {
                        SkySectionHeader(title: "Other weather services", systemImage: "globe")
                    }
                    .glassRow()
                }
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
                            Text(WeatherFormat.temperature(row.high))
                                .font(.body.weight(.bold))
                                .frame(width: 40, alignment: .trailing)
                            Text(WeatherFormat.temperature(row.low))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 40, alignment: .trailing)
                        }
                        .fontDesign(.rounded)
                    }
                } header: {
                    SkySectionHeader(title: "High and low by model", systemImage: "chart.bar.xaxis")
                } footer: {
                    Text(footer)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .glassRow()
            }
            Section {
                NavigationLink {
                    ModelGridView(location: location, timeZone: timeZone, appDays: appDays)
                } label: {
                    Label {
                        Text("All models, all 10 days").font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "square.grid.3x3").foregroundStyle(Brand.gold)
                    }
                }
                NavigationLink {
                    AccuracyView()
                } label: {
                    Label {
                        Text("Which model has been most accurate?").font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "target").foregroundStyle(Brand.gold)
                    }
                }
            }
            .glassRow()
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
            ? BlendRegion.summary(at: location)
            : "Khan Weather's temperatures here come from \(usedModel.name)."
        return source + " The highlighted row's high and low come from the app's midnight-to-midnight hourly forecast, on the same 24-hour window as the other models." + " High-res models only reach a day or two ahead. Models via Open-Meteo.com (CC BY 4.0)."
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
            async let extTask = RelayExtrasProvider().consensus(near: location)
            let sameDay = try await ModelComparisonProvider().days(at: location)
                .filter { calendar.isDate($0.date, inSameDayAs: day.date) }
            let used = usedModel
            let ordered = sameDay.filter { $0.model == used } + sameDay.filter { $0.model != used }
            rows = ModelComparisonProvider.showingApp(ordered, appDays: appDays.isEmpty ? [day] : appDays, used: used, timeZone: timeZone)
            externalSources = await extTask?.sources ?? []
            failed = rows.isEmpty
        } catch {
            failed = true
        }
    }
}
