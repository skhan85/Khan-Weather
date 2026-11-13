import SwiftUI
import WidgetKit
import WeatherCore

struct ContentView: View {
    @StateObject private var model = WeatherViewModel()
    @StateObject private var places = SavedPlacesStore()
    @State private var showingPlaces = false
    @State private var showingSettings = false
    // Watched so the forecast redraws when units change in Settings.
    @AppStorage(UnitSettings.temperatureKey) private var temperatureUnit = TemperatureUnit.celsius.rawValue
    @AppStorage(UnitSettings.windKey) private var windUnit = WindUnit.kmh.rawValue
    @AppStorage(UnitSettings.precipitationKey) private var precipitationUnit = PrecipitationUnit.metric.rawValue
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
                                 alerts: model.alerts,
                                 placeName: model.placeName,
                                 isSavedPlace: places.selected != nil,
                                 attribution: model.provider.attribution,
                                 usingFallbackLocation: model.usingFallbackLocation)
                        .id("\(temperatureUnit)-\(windUnit)-\(precipitationUnit)")
                        .refreshable { await reload() }
                }
            }
            .navigationTitle("Khan Weather")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Place", selection: $places.selectedID) {
                            Label("Current location", systemImage: "location.fill").tag(UUID?.none)
                            ForEach(places.places) { place in
                                Text(place.name).tag(UUID?.some(place.id))
                            }
                        }
                        Divider()
                        Button { showingPlaces = true } label: {
                            Label("Add or edit places", systemImage: "pencil")
                        }
                    } label: {
                        Label("Places", systemImage: places.selected == nil ? "location.circle" : "mappin.circle")
                    }
                }
            }
            .sheet(isPresented: $showingPlaces) {
                PlacesView(store: places)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .task { await reload() }
        .onChange(of: places.selectedID) { _, _ in
            Task { await reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
    }

    private func reload() async {
        await model.refresh(place: places.selected)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private struct ForecastList: View {
    let forecast: Forecast
    let alerts: [WeatherAlert]
    let placeName: String?
    let isSavedPlace: Bool
    let attribution: String
    let usingFallbackLocation: Bool

    /// Short credit line; the full credits are one tap away.
    private var sourceNames: String {
        "Sources: " + Credits.shortNames(forecast: forecast, alerts: alerts).joined(separator: ", ")
    }

    var body: some View {
        List {
            if usingFallbackLocation {
                Section {
                    Label("Location is off, so this shows Toronto. Turn on location in Settings for weather where you are.",
                          systemImage: "location.slash")
                        .font(.footnote)
                }
            }

            if !alerts.isEmpty {
                Section {
                    ForEach(alerts) { AlertBanner(alert: $0, timeZone: forecast.timeZone) }
                }
            }

            Section {
                CurrentConditionsView(current: forecast.current, placeName: placeName, isSavedPlace: isSavedPlace,
                                      observation: forecast.observation, timeZone: forecast.timeZone)
                if let nowcast = forecast.nowcast() {
                    Label(nowcast.text, systemImage: nowcast.kind == .rain ? "umbrella.fill" : "snowflake")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(nowcast.kind == .rain ? Color.blue : Color.cyan)
                }
            }

            Section("Next 24 hours") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(forecast.upcomingHours()) { hour in
                            NavigationLink {
                                HourDetailView(hour: hour, timeZone: forecast.timeZone)
                            } label: {
                                VStack(spacing: 6) {
                                    Text(hour.time, format: Date.FormatStyle(timeZone: forecast.timeZone).hour())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ConditionIcon(condition: hour.condition, isDay: hour.isDay)
                                        .frame(height: 22)
                                    Text(WeatherFormat.temperature(hour.temperature))
                                        .font(.headline)
                                    PrecipChance(probability: hour.precipitationProbability,
                                                 kind: hour.precipitationKind, font: .caption2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // A new forecast starts the row back at "now" instead of keeping an old scroll position.
                .id(forecast.fetchedAt)
            }

            Section("\(forecast.daily.count)-day forecast") {
                ForEach(forecast.daily) { day in
                    NavigationLink {
                        DayDetailView(day: day, hours: forecast.hours(on: day), timeZone: forecast.timeZone)
                    } label: {
                    HStack {
                        Text(day.date, format: Date.FormatStyle(timeZone: forecast.timeZone).weekday(.abbreviated))
                            .frame(width: 48, alignment: .leading)
                        ConditionIcon(condition: day.condition)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            PrecipChance(probability: day.precipitationProbability, kind: day.precipitationKind)
                            if let totals = WeatherFormat.precipitationTotals(rainMm: day.rainSum, snowCm: day.snowfallSum) {
                                Text(totals)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(WeatherFormat.temperature(day.low))
                            .foregroundStyle(.secondary)
                        Text(WeatherFormat.temperature(day.high))
                            .frame(width: 44, alignment: .trailing)
                    }
                    }
                }
            }

            Section {
                NavigationLink {
                    SourcesView(forecast: forecast, alerts: alerts, isSavedPlace: isSavedPlace)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceNames)
                            .font(.footnote)
                        Text("Updated \(forecast.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct CurrentConditionsView: View {
    let current: CurrentConditions
    var placeName: String?
    var isSavedPlace = false
    var observation: Observation?
    var timeZone: TimeZone = .current

    var body: some View {
        VStack(spacing: 8) {
            if let placeName {
                Label(placeName, systemImage: isSavedPlace ? "mappin" : "location.fill")
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
                    Label(WeatherFormat.wind(wind), systemImage: "wind")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let observation, observation.isLocal {
                Text(Self.localCaption(observation, from: placeName, timeZone: timeZone))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let observation {
                Text("Sky from \(observation.stationName)\(Self.distance(observation, from: placeName)). Temperature is the forecast for your spot.")
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

    /// ", 13 km from Oakville": the distance is to the forecast spot, not to the town in the station's name.
    static func distance(_ o: Observation, from place: String?) -> String {
        guard let km = o.distanceKm else { return "" }
        return ", \(Int(km.rounded())) km from \(place ?? "you")"
    }

    static func localCaption(_ o: Observation, from place: String? = nil, timeZone: TimeZone) -> String {
        let time = o.observedAt.formatted(Date.FormatStyle(time: .shortened, timeZone: timeZone))
        var text = "Observed \(time) at \(o.stationName)\(distance(o, from: place))"
        text += "."
        return text
    }
}
