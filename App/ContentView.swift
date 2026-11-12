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
                                 placeName: model.placeName,
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
    let placeName: String?
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
                CurrentConditionsView(current: forecast.current, placeName: placeName,
                                      observation: forecast.observation, timeZone: forecast.timeZone)
            }

            Section("Next 24 hours") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(forecast.upcomingHours()) { hour in
                            VStack(spacing: 6) {
                                Text(hour.time, format: Date.FormatStyle(timeZone: forecast.timeZone).hour())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ConditionIcon(condition: hour.condition)
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
                        Text(day.date, format: Date.FormatStyle(timeZone: forecast.timeZone).weekday(.abbreviated))
                            .frame(width: 48, alignment: .leading)
                        ConditionIcon(condition: day.condition)
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
                if forecast.observation != nil {
                    Link("Observations: Environment and Climate Change Canada",
                         destination: URL(string: "https://weather.gc.ca/")!)
                        .font(.footnote)
                }
                Text("Updated \(forecast.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CurrentConditionsView: View {
    let current: CurrentConditions
    var placeName: String?
    var observation: Observation?
    var timeZone: TimeZone = .current

    var body: some View {
        VStack(spacing: 8) {
            if let placeName {
                Label(placeName, systemImage: "location.fill")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
            }
            ConditionIcon(condition: current.condition, isDay: current.isDay)
                .font(.system(size: 56))
            Text(WeatherFormat.temperature(current.temperature))
                .font(.system(size: 64, weight: .thin))
            Text(observation?.conditionText ?? current.condition.description)
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
            if let observation, observation.isLocal {
                Text("Observed at \(observation.stationName), \(observation.observedAt.formatted(Date.FormatStyle(time: .shortened, timeZone: timeZone)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let observation {
                Text("Sky from \(observation.stationName) (\(Int((observation.distanceKm ?? 0).rounded())) km away). Temperature is the forecast for your spot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Model estimate (no nearby station)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
