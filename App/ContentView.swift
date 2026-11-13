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
    @AppStorage(UnitSettings.pressureKey) private var pressureUnit = PressureUnit.kPa.rawValue
    @AppStorage(UnitSettings.distanceKey) private var distanceUnit = DistanceUnit.km.rawValue
    @AppStorage(DisplaySettings.appearanceKey) private var appearance = Appearance.system.rawValue
    @AppStorage(DisplaySettings.clockKey) private var clock = ClockStyle.automatic.rawValue
    @AppStorage(DisplaySettings.mainTemperatureKey) private var mainTemperature = MainTemperature.actual.rawValue
    @AppStorage(DisplaySettings.hourlyCountKey) private var hourlyCount = 24
    @AppStorage(DisplaySettings.showDetailsKey) private var showDetails = true
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
                        .id([temperatureUnit, windUnit, precipitationUnit, pressureUnit, distanceUnit, clock,
                             mainTemperature, String(hourlyCount), String(showDetails)].joined(separator: "-"))
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
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
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
    @AppStorage(DisplaySettings.hourlyCountKey) private var hourlyCount = 24
    @AppStorage(DisplaySettings.showDetailsKey) private var showDetails = true

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
                if showDetails {
                    TodayDetailsView(forecast: forecast)
                }
                if let nowcast = forecast.nowcast() {
                    Label(nowcast.text, systemImage: nowcast.kind == .rain ? "umbrella.fill" : "snowflake")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(nowcast.kind == .rain ? Color.blue : Color.cyan)
                }
            }

            Section("Next \(hourlyCount) hours") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(forecast.upcomingHours(count: hourlyCount)) { hour in
                            NavigationLink {
                                HourDetailView(hour: hour, timeZone: forecast.timeZone)
                            } label: {
                                VStack(spacing: 6) {
                                    Text(TimeText.hour(hour.time, forecast.timeZone))
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
                        DayDetailView(day: day, hours: forecast.hours(on: day), timeZone: forecast.timeZone,
                                      location: forecast.location)
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
                        Text("Updated \(TimeText.time(forecast.fetchedAt, .current))")
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
    @AppStorage(DisplaySettings.mainTemperatureKey) private var mainTemperature = MainTemperature.actual.rawValue

    private var feelsFirst: Bool { mainTemperature == MainTemperature.feelsLike.rawValue }

    var body: some View {
        VStack(spacing: 8) {
            if let placeName {
                Label(placeName, systemImage: isSavedPlace ? "mappin" : "location.fill")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
            }
            ConditionIcon(condition: current.condition, isDay: current.isDay)
                .font(.system(size: 56))
            Text(WeatherFormat.temperature(feelsFirst ? current.feelsLike : current.temperature))
                .font(.system(size: 64, weight: .thin))
            Text(observation?.conditionText ?? current.condition.description)
                .font(.title3)
            Group {
                if feelsFirst {
                    Text("\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)). Actual \(WeatherFormat.temperature(current.temperature))")
                } else {
                    Text("\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)) \(WeatherFormat.temperature(current.feelsLike))")
                }
            }
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
        guard let text = WeatherFormat.distance(o.distanceKm) else { return "" }
        return ", \(text) from \(place ?? "you")"
    }

    static func localCaption(_ o: Observation, from place: String? = nil, timeZone: TimeZone) -> String {
        let time = TimeText.time(o.observedAt, timeZone)
        var text = "Observed \(time) at \(o.stationName)\(distance(o, from: place))"
        text += "."
        return text
    }
}

/// A compact grid of today's extra numbers under the current conditions.
struct TodayDetailsView: View {
    let forecast: Forecast

    private struct Tile: Identifiable {
        let title: String
        let value: String
        let systemImage: String
        var id: String { title }
    }

    private var tiles: [Tile] {
        let now = forecast.current
        let hour = forecast.hour()
        let day = forecast.day()
        let tz = forecast.timeZone
        var list: [Tile] = []
        func add(_ title: String, _ value: String?, _ image: String) {
            if let value { list.append(Tile(title: title, value: value, systemImage: image)) }
        }
        add("UV index", WeatherFormat.uvLevel(hour?.uvIndex), "sun.max")
        add("Pressure", WeatherFormat.pressure(now.pressure), "gauge.with.dots.needle.33percent")
        add("Visibility", hour?.visibility.flatMap { WeatherFormat.distance($0 / 1000) }, "eye")
        add("Dew point", hour?.dewPoint.map { WeatherFormat.temperature($0) }, "thermometer.medium")
        if let gusts = now.windGusts ?? hour?.windGusts {
            var text = WeatherFormat.wind(gusts)
            if let dir = WeatherFormat.compass(now.windDirection) { text = "\(dir), \(text)" }
            add("Gusts", text, "wind")
        }
        add("Sunrise", day?.sunrise.map { TimeText.time($0, tz) }, "sunrise")
        add("Sunset", day?.sunset.map { TimeText.time($0, tz) }, "sunset")
        if let rain = day?.rainSum, let snow = day?.snowfallSum {
            add("Today's total", WeatherFormat.precipitationTotals(rainMm: rain, snowCm: snow), "drop")
        }
        return list
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Label(tile.title, systemImage: tile.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(tile.value)
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}
