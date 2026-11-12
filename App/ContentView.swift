import SwiftUI
import WidgetKit
import WeatherCore

struct ContentView: View {
    @StateObject private var model = WeatherViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Getting your weather…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't load weather", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.refresh() } }
                    }
                case .loaded(let forecast):
                    ForecastList(forecast: forecast,
                                 attribution: model.provider.attribution,
                                 usingFallbackLocation: model.usingFallbackLocation)
                        .refreshable { await reload() }
                }
            }
            .navigationTitle("Khan Weather")
        }
        .task { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
    }

    private func reload() async {
        await model.refresh()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private struct ForecastList: View {
    let forecast: Forecast
    let attribution: String
    let usingFallbackLocation: Bool

    var body: some View {
        List {
            if usingFallbackLocation {
                Section {
                    Label("Location is off, so this shows Toronto. Turn on location in Settings for weather where you are.",
                          systemImage: "location.slash")
                        .font(.footnote)
                }
            }

            Section {
                CurrentConditionsView(current: forecast.current)
            }

            Section("Next 24 hours") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(forecast.upcomingHours()) { hour in
                            VStack(spacing: 6) {
                                Text(hour.time, format: .dateTime.hour().timeZone(forecast.timeZone))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: hour.condition.symbolName())
                                    .symbolRenderingMode(.multicolor)
                                    .frame(height: 22)
                                Text(WeatherFormat.temperature(hour.temperature))
                                    .font(.headline)
                                if let pop = hour.precipitationProbability, pop >= 10 {
                                    Text(WeatherFormat.percent(pop))
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("\(forecast.daily.count)-day forecast") {
                ForEach(forecast.daily) { day in
                    HStack {
                        Text(day.date, format: .dateTime.weekday(.abbreviated).timeZone(forecast.timeZone))
                            .frame(width: 48, alignment: .leading)
                        Image(systemName: day.condition.symbolName())
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 32)
                        if let pop = day.precipitationProbability, pop >= 10 {
                            Text(WeatherFormat.percent(pop))
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        Spacer()
                        Text(WeatherFormat.temperature(day.low))
                            .foregroundStyle(.secondary)
                        Text(WeatherFormat.temperature(day.high))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section {
                Link(attribution, destination: URL(string: "https://open-meteo.com/")!)
                    .font(.footnote)
                Text("Updated \(forecast.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CurrentConditionsView: View {
    let current: CurrentConditions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: current.condition.symbolName(isDay: current.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 56))
            Text(WeatherFormat.temperature(current.temperature))
                .font(.system(size: 64, weight: .thin))
            Text(current.condition.description)
                .font(.title3)
            Text("\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)) \(WeatherFormat.temperature(current.feelsLike))")
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                if let humidity = current.humidity {
                    Label(WeatherFormat.percent(humidity), systemImage: "humidity")
                }
                if let wind = current.windSpeed {
                    Label("\(Int(wind.rounded())) km/h", systemImage: "wind")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
