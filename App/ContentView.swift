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
                        .tint(.white)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't load weather", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.refresh() } }
                            .buttonStyle(.bordered)
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
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: stateKey)
            .skyBackground(sky.condition, isDay: sky.isDay)
            .tint(.white)
            .navigationTitle("Khan Weather")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .accessibilityLabel("Khan Weather")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tint(.white)
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
                    .tint(.white)
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

    /// The sky to draw: the current conditions once loaded, a soft day sky before that.
    private var sky: (condition: WeatherCondition, isDay: Bool) {
        if case .loaded(let f) = model.state { return (f.current.condition, f.current.isDay) }
        return (.partlyCloudy, true)
    }

    private var stateKey: String {
        switch model.state {
        case .loading: return "loading"
        case .failed: return "failed"
        case .loaded: return "loaded"
        }
    }

    private func reload() async {
        model.onCurrentLocation = { AlertNotifier.rememberCurrentLocation($0) }
        await model.refresh(place: places.selected)
        AlertNotifier.markSeen(model.alerts)
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

    /// Environment Canada's mosaic covers Canada and the northern US.
    static func radarCovers(_ c: Coordinate) -> Bool {
        (35...75).contains(c.latitude) && (-145 ... -50).contains(c.longitude)
    }

    /// Short credit line; the full credits are one tap away.
    private var sourceNames: String {
        "Sources: " + Credits.shortNames(forecast: forecast, alerts: alerts).joined(separator: ", ")
    }

    private var weekLow: Double { forecast.daily.map(\.low).min() ?? 0 }
    private var weekHigh: Double { forecast.daily.map(\.high).max() ?? 0 }

    var body: some View {
        List {
            if usingFallbackLocation {
                Section {
                    Label("Location is off, so this shows Toronto. Turn on location in Settings for weather where you are.",
                          systemImage: "location.slash")
                        .font(.footnote)
                }
                .glassRow()
            }

            if !alerts.isEmpty {
                Section {
                    ForEach(alerts) { AlertBanner(alert: $0, timeZone: forecast.timeZone) }
                }
            }

            Section {
                CurrentConditionsView(current: forecast.current, placeName: placeName, isSavedPlace: isSavedPlace,
                                      observation: forecast.observation, timeZone: forecast.timeZone,
                                      today: forecast.day())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let nowcast = forecast.nowcast() {
                Section {
                    Label(nowcast.text, systemImage: nowcast.kind == .rain ? "umbrella.fill" : "snowflake")
                        .font(.subheadline.weight(.semibold))
                        .symbolRenderingMode(.multicolor)
                }
                .glassRow()
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(Array(forecast.upcomingHours(count: hourlyCount).enumerated()), id: \.element.id) { index, hour in
                            NavigationLink {
                                HourDetailView(hour: hour, timeZone: forecast.timeZone)
                            } label: {
                                VStack(spacing: 8) {
                                    Text(index == 0 ? "Now" : TimeText.hour(hour.time, forecast.timeZone))
                                        .font(.footnote.weight(index == 0 ? .bold : .semibold))
                                        .foregroundStyle(.white.opacity(index == 0 ? 1 : 0.85))
                                    ConditionIcon(condition: hour.condition, isDay: hour.isDay)
                                        .font(.title3)
                                        .frame(height: 26)
                                    Text(WeatherFormat.temperature(hour.temperature))
                                        .font(.body.weight(.semibold))
                                    PrecipChance(probability: hour.precipitationProbability,
                                                 kind: hour.precipitationKind, font: .caption2.weight(.semibold))
                                        .frame(height: 14)
                                }
                                .frame(minWidth: 50)
                                .padding(.vertical, 8)
                                .background(index == 0 ? Color.white.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                // A new forecast starts the row back at "now" instead of keeping an old scroll position.
                .id(forecast.fetchedAt)
            } header: {
                SkySectionHeader(title: "Next \(hourlyCount) hours", systemImage: "clock")
            }
            .glassRow()

            Section {
                ForEach(Array(forecast.daily.enumerated()), id: \.element.id) { index, day in
                    NavigationLink {
                        DayDetailView(day: day, hours: forecast.hours(on: day), timeZone: forecast.timeZone,
                                      location: forecast.location)
                    } label: {
                        DailyRow(day: day, isToday: index == 0, timeZone: forecast.timeZone,
                                 weekLow: weekLow, weekHigh: weekHigh,
                                 current: index == 0 ? forecast.current.temperature : nil)
                    }
                }
            } header: {
                SkySectionHeader(title: "\(forecast.daily.count)-day forecast", systemImage: "calendar")
            }
            .glassRow()

            if showDetails {
                Section {
                    TodayDetailsView(forecast: forecast)
                } header: {
                    SkySectionHeader(title: "Today", systemImage: "sun.horizon")
                }
                .glassRow()
            }

            if Self.radarCovers(forecast.location) {
                Section {
                    NavigationLink {
                        RadarMapView(center: forecast.location)
                    } label: {
                        Label("Radar map", systemImage: "dot.radiowaves.left.and.right")
                            .font(.body.weight(.medium))
                    }
                }
                .glassRow()
            }

            Section {
                NavigationLink {
                    SourcesView(forecast: forecast, alerts: alerts, isSavedPlace: isSavedPlace)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceNames)
                            .font(.footnote)
                        Text("Updated \(TimeText.time(forecast.fetchedAt, .current))")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
            .glassRow()
        }
        .listSectionSpacing(14)
    }
}

/// One day in the 10-day list: weekday, icon, chance of rain or snow, and the low-to-high bar.
private struct DailyRow: View {
    let day: DailyForecast
    let isToday: Bool
    let timeZone: TimeZone
    let weekLow: Double
    let weekHigh: Double
    var current: Double?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(isToday ? "Today" : day.date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated)))
                    .font(.body.weight(.semibold))
                if let totals = WeatherFormat.precipitationTotals(rainMm: day.rainSum, snowCm: day.snowfallSum) {
                    Text(totals)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(width: 62, alignment: .leading)
            VStack(spacing: 1) {
                ConditionIcon(condition: day.condition)
                    .font(.title3)
                PrecipChance(probability: day.precipitationProbability, kind: day.precipitationKind,
                             font: .caption2.weight(.semibold), showsIcon: false)
            }
            .frame(width: 36)
            Text(WeatherFormat.temperature(day.low))
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 36, alignment: .trailing)
            TemperatureRangeBar(low: day.low, high: day.high, weekLow: weekLow, weekHigh: weekHigh, current: current)
            Text(WeatherFormat.temperature(day.high))
                .font(.body.weight(.semibold))
                .frame(width: 36, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

struct CurrentConditionsView: View {
    let current: CurrentConditions
    var placeName: String?
    var isSavedPlace = false
    var observation: Observation?
    var timeZone: TimeZone = .current
    var today: DailyForecast? = nil
    @AppStorage(DisplaySettings.mainTemperatureKey) private var mainTemperature = MainTemperature.actual.rawValue

    private var feelsFirst: Bool { mainTemperature == MainTemperature.feelsLike.rawValue }

    var body: some View {
        VStack(spacing: 6) {
            if let placeName {
                Label(placeName, systemImage: isSavedPlace ? "mappin" : "location.fill")
                    .font(.title2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(WeatherFormat.temperature(feelsFirst ? current.feelsLike : current.temperature))
                .font(.system(size: 96, weight: .thin, design: .rounded))
                .contentTransition(.numericText())
                .padding(.vertical, -6)
            HStack(spacing: 8) {
                ConditionIcon(condition: current.condition, isDay: current.isDay)
                    .font(.title)
                    .symbolEffect(.bounce, value: current.time)
                Text(observation?.conditionText ?? current.condition.description)
                    .font(.title3.weight(.medium))
            }
            Group {
                if feelsFirst {
                    Text("\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)). Actual \(WeatherFormat.temperature(current.temperature))")
                } else {
                    Text("\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)) \(WeatherFormat.temperature(current.feelsLike))")
                }
            }
            .font(.headline)
            if let today {
                Text("H:\(WeatherFormat.temperature(today.high))   L:\(WeatherFormat.temperature(today.low))")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.88))
            }
            HStack(spacing: 20) {
                if let humidity = current.humidity {
                    Label(WeatherFormat.percent(humidity), systemImage: "humidity.fill")
                }
                if let wind = current.windSpeed {
                    Label(WeatherFormat.wind(wind), systemImage: "wind")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.top, 2)
            Group {
                if let observation, observation.isLocal {
                    Text(Self.localCaption(observation, from: placeName, timeZone: timeZone))
                } else if let observation {
                    Text("Sky from \(observation.stationName)\(Self.distance(observation, from: placeName)). Temperature is the forecast for your spot.")
                } else {
                    Text("Model estimate (no nearby station)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.88))
            .multilineTextAlignment(.center)
            .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
        add("UV index", WeatherFormat.uvLevel(hour?.uvIndex), "sun.max.fill")
        add("Pressure", WeatherFormat.pressure(now.pressure), "gauge.with.dots.needle.33percent")
        add("Visibility", hour?.visibility.flatMap { WeatherFormat.distance($0 / 1000) }, "eye")
        add("Dew point", hour?.dewPoint.map { WeatherFormat.temperature($0) }, "thermometer.medium")
        if let gusts = now.windGusts ?? hour?.windGusts {
            var text = WeatherFormat.wind(gusts)
            if let dir = WeatherFormat.compass(now.windDirection) { text = "\(dir), \(text)" }
            add("Gusts", text, "wind")
        }
        add("Sunrise", day?.sunrise.map { TimeText.time($0, tz) }, "sunrise.fill")
        add("Sunset", day?.sunset.map { TimeText.time($0, tz) }, "sunset.fill")
        if let rain = day?.rainSum, let snow = day?.snowfallSum {
            add("Today's total", WeatherFormat.precipitationTotals(rainMm: rain, snowCm: snow), "drop")
        }
        return list
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 4) {
                    Label(tile.title, systemImage: tile.systemImage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(tile.value)
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}
