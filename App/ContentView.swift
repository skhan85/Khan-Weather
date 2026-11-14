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
    @AppStorage(DisplaySettings.showAirQualityKey) private var showAirQuality = true
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
                                 airQuality: model.airQuality,
                                 placeName: model.placeName,
                                 isSavedPlace: places.selected != nil,
                                 attribution: model.provider.attribution,
                                 usingFallbackLocation: model.usingFallbackLocation)
                        .id([temperatureUnit, windUnit, precipitationUnit, pressureUnit, distanceUnit, clock,
                             mainTemperature, String(hourlyCount), String(showDetails), String(showAirQuality)].joined(separator: "-"))
                        .refreshable { await reload() }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: stateKey)
            .skyBackground(sky.condition, isDay: sky.isDay)
            .tint(.white)
            .navigationTitle("Khan Weather")
            .navigationBarTitleDisplayMode(.inline)
            // Back buttons on the hour and day screens show just a white arrow, not "Khan Weather".
            .toolbarRole(.editor)
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
                    .tint(.blue)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .tint(.blue)
            }
        }
        .tint(.white)
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
        if places.selected == nil, case .loaded(let f) = model.state { AlertNotifier.markRainSeen(f.nowcast()) }
        WidgetCenter.shared.reloadAllTimelines()
        // Warm up the saved places so the first switch to one is quick.
        Task { await model.prefetch(places.places) }
    }
}

private struct ForecastList: View {
    let forecast: Forecast
    let alerts: [WeatherAlert]
    let airQuality: AirQuality?
    let placeName: String?
    let isSavedPlace: Bool
    let attribution: String
    let usingFallbackLocation: Bool
    @AppStorage(DisplaySettings.hourlyCountKey) private var hourlyCount = 24
    @AppStorage(DisplaySettings.showDetailsKey) private var showDetails = true
    @AppStorage(DisplaySettings.showAirQualityKey) private var showAirQuality = true

    /// Environment Canada's mosaic covers Canada and the northern US.
    static func radarCovers(_ c: Coordinate) -> Bool {
        (35...75).contains(c.latitude) && (-145 ... -50).contains(c.longitude)
    }

    /// Short credit line; the full credits are one tap away.
    private var sourceNames: String {
        "Sources: " + Credits.shortNames(forecast: forecast, alerts: alerts).joined(separator: ", ")
    }

    /// The next hours, with "Now" showing the same temperature as the Now card
    /// (which may come from a nearby station rather than the forecast model).
    private var hoursStartingNow: [HourlyForecast] {
        var hours = forecast.upcomingHours(count: hourlyCount)
        if !hours.isEmpty {
            hours[0].temperature = forecast.current.temperature
            hours[0].condition = forecast.current.condition
        }
        return hours
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
                                      today: forecast.day(), outlook: Outlook.text(forecast))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section {
                HourlyCurve(hours: hoursStartingNow, timeZone: forecast.timeZone)
                    // A new forecast starts the strip back at "now" instead of keeping an old scroll position.
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

            if showAirQuality, let airQuality, airQuality.usAQI != nil {
                Section {
                    AirQualityView(air: airQuality)
                } header: {
                    SkySectionHeader(title: "Air quality", systemImage: "aqi.medium")
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
        .fontDesign(.rounded)
    }
}

/// One plain sentence about the next few hours, e.g. "Cooling to 1° by 11 PM."
enum Outlook {
    static func text(_ forecast: Forecast) -> String? {
        if let nowcast = forecast.nowcast() { return nowcast.text }
        let next = forecast.upcomingHours(count: 7)
        guard let now = next.first, next.count > 3 else { return nil }
        let later = next.dropFirst()
        let tz = forecast.timeZone
        // Rain or snow coming up is the most useful thing to say.
        if let wet = later.first(where: { ($0.precipitationProbability ?? 0) >= 50 }) {
            return "\(wet.precipitationKind.noun.capitalized) likely around \(TimeText.hour(wet.time, tz))."
        }
        let target = later.last!
        let change = target.temperature - now.temperature
        let at = TimeText.hour(target.time, tz)
        if change <= -2 { return "Cooling to \(WeatherFormat.temperature(target.temperature)) by \(at)." }
        if change >= 2 { return "Warming to \(WeatherFormat.temperature(target.temperature)) by \(at)." }
        if target.condition != now.condition {
            return "\(target.condition.description) by \(at)."
        }
        return "Steady around \(WeatherFormat.temperature(now.temperature)) for the next few hours."
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
                    .font(.body.weight(.bold))
                    .foregroundStyle(isToday ? Brand.gold : .white)
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
                IconBadge(condition: day.condition, size: 34)
                PrecipChance(probability: day.precipitationProbability, kind: day.precipitationKind,
                             font: .caption2.weight(.semibold), showsIcon: false)
            }
            .frame(width: 40)
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
    /// "Cooling to 1° by 11 PM."
    var outlook: String? = nil
    @AppStorage(DisplaySettings.mainTemperatureKey) private var mainTemperature = MainTemperature.actual.rawValue

    private var feelsFirst: Bool { mainTemperature == MainTemperature.feelsLike.rawValue }

    private var feelsText: String {
        if feelsFirst {
            return "\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)). Actual \(WeatherFormat.temperature(current.temperature))"
        }
        return "\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)) \(WeatherFormat.temperature(current.feelsLike))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let placeName {
                    Label(placeName, systemImage: isSavedPlace ? "mappin" : "location.fill")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer()
                Text("NOW")
                    .font(.caption.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Brand.gold))
            }
            HStack(alignment: .center, spacing: 16) {
                IconBadge(condition: current.condition, isDay: current.isDay, size: 96)
                    .symbolEffect(.bounce, value: current.time)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WeatherFormat.temperature(feelsFirst ? current.feelsLike : current.temperature))
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(observation?.conditionText ?? current.condition.description)
                        .font(.title3.weight(.semibold))
                    Text(feelsText)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            if let outlook {
                Text(outlook)
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.18)))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Brand.gold).frame(width: 4).padding(.vertical, 6)
                    }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let today {
                        FactChip(text: "\(WeatherFormat.temperature(today.high)) / \(WeatherFormat.temperature(today.low))",
                                 systemImage: "thermometer.medium")
                    }
                    if let humidity = current.humidity {
                        FactChip(text: WeatherFormat.percent(humidity), systemImage: "humidity.fill")
                    }
                    if let wind = current.windSpeed {
                        FactChip(text: WeatherFormat.wind(wind), systemImage: "wind")
                    }
                }
            }
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
        }
        .foregroundStyle(.white)
        .fontDesign(.rounded)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.3), lineWidth: 1))
        }
        .padding(.horizontal, 16)
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
