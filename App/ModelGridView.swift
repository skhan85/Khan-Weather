import SwiftUI
import WeatherCore

/// Every model's high and low for every day, side by side. Columns where the models
/// spread widely are marked, so it's easy to see which days are unsure.
struct ModelGridView: View {
    let location: Coordinate
    let timeZone: TimeZone
    /// The app's displayed days, so the Khan Weather row matches the rest of the app.
    var appDays: [DailyForecast] = []

    @State private var days: [ModelDay] = []
    @State private var loading = true

    private let nameWidth: CGFloat = 112
    private let cellWidth: CGFloat = 58
    private let rowHeight: CGFloat = 54

    private var models: [WeatherModel] {
        let used = WeatherModel.usedForTemperatures(at: location)
        let present = Set(days.map(\.model))
        return [used] + WeatherModel.allCases.filter { $0 != used && present.contains($0) }
    }
    private var dates: [Date] { Array(Set(days.map(\.date))).sorted() }

    var body: some View {
        Group {
            if loading {
                ProgressView("Asking each model…").tint(.white)
            } else if days.isEmpty {
                ContentUnavailableView("Couldn't load the models", systemImage: "exclamationmark.triangle",
                                       description: Text("Check your connection and try again."))
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 0) {
                            nameColumn
                            ScrollView(.horizontal, showsIndicators: false) { grid }
                        }
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.22)))
                        Text("High over low for each day. The bars under a day show how well the models agree. Models via Open-Meteo.com (CC BY 4.0).")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .fontDesign(.rounded)
        .background { SkyBackground(condition: .partlyCloudy, isDay: true).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle("10-day models")
        .skyTitle("10-day models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)
            ForEach(models, id: \.self) { model in
                Text(model.name)
                    .font(.caption.weight(model == models.first ? .heavy : .semibold))
                    .foregroundStyle(model == models.first ? Brand.gold : .white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                    .padding(.leading, 10)
            }
        }
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(dates.enumerated()), id: \.element) { index, date in
                VStack(spacing: 0) {
                    VStack(spacing: 3) {
                        Text(index == 0 ? "Today" : date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated)))
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(index == 0 ? Brand.gold : .white)
                        if let confidence = confidence(on: date) { ConfidenceMark(confidence: confidence) }
                    }
                    .frame(height: 44)
                    ForEach(models, id: \.self) { model in
                        cell(days.first { $0.model == model && $0.date == date })
                            .frame(width: cellWidth, height: rowHeight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: ModelDay?) -> some View {
        if let day {
            VStack(spacing: 1) {
                ConditionIcon(condition: day.condition).font(.caption)
                Text(WeatherFormat.temperature(day.high)).font(.subheadline.weight(.bold))
                Text(WeatherFormat.temperature(day.low)).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.7))
            }
        } else {
            Text("–").foregroundStyle(.white.opacity(0.4))
        }
    }

    /// From the spread of the day's highs and lows across the models (not counting the blend).
    private func confidence(on date: Date) -> ForecastConfidence? {
        let same = days.filter { $0.date == date && $0.model != .blend && $0.model != .bestMatch }
        let highs = same.compactMap(\.high), lows = same.compactMap(\.low)
        guard highs.count >= 3, let hMax = highs.max(), let hMin = highs.min(),
              let lMax = lows.max(), let lMin = lows.min() else { return nil }
        let spread = ((hMax - hMin) + (lMax - lMin)) / 2
        if spread <= 2.5 { return .sure }
        if spread <= 4.5 { return .fair }
        return .unsure
    }

    private func load() async {
        defer { loading = false }
        let all = (try? await ModelComparisonProvider().days(at: location)) ?? []
        days = ModelComparisonProvider.showingApp(all, appDays: appDays,
                                                  used: WeatherModel.usedForTemperatures(at: location), timeZone: timeZone)
    }
}
