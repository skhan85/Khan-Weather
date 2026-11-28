import SwiftUI
import WidgetKit
import WeatherCore

struct ContentView: View {
    @StateObject private var model = WeatherViewModel()
    @StateObject private var places = SavedPlacesStore()
    @State private var showingPlaces = false
    @State private var showingSettings = false
    @State private var lastReload: Date = .distantPast
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
    @AppStorage(ObservationSource.hyperlocalKey) private var useHyperlocalPWS = ObservationSource.hyperlocalDefault
    // bool(forKey:) also reads "-unitsChosen YES" from the launch arguments (CI screenshots).
    @State private var unitsChosen = UserDefaults.standard.bool(forKey: UnitSettings.chosenKey)
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
                        Button("Try again") { Task { await reload() } }
                            .buttonStyle(.bordered)
                    }
                case .loaded(let forecast):
                    ForecastList(forecast: forecast,
                                 alerts: model.alerts,
                                 airQuality: model.airQuality,
                                 normals: model.normals,
                                 placeName: model.placeName,
                                 isSavedPlace: places.selected != nil,
                                 attribution: model.provider.attribution,
                                 usingFallbackLocation: model.usingFallbackLocation,
                                 isRefreshing: model.isRefreshing,
                                 ownReport: places.selected == nil ? model.activeOwnReport : nil,
                                 // Reports are for where you're standing, so only on Current location.
                                 onReport: places.selected == nil && !model.usingFallbackLocation
                                     ? { model.report($0) } : nil,
                                 onUndoReport: { model.undoReport() })
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
            // The first time the app opens: which units to use.
            .fullScreenCover(isPresented: Binding(get: { !unitsChosen }, set: { if !$0 { unitsChosen = true } })) {
                UnitsWelcomeView()
            }
        }
        .tint(.white)
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        .task { await reload() }
        .onChange(of: places.selectedID) { _, _ in
            Task { await reload() }
        }
        .onChange(of: useHyperlocalPWS) { _, _ in Task { await reload() } }
        .onChange(of: scenePhase) { _, phase in
            // Coming back within two minutes doesn't refetch (Open-Meteo answers HTTP 429 when hit too often).
            if phase == .active, Date().timeIntervalSince(lastReload) > 120 { Task { await reload() } }
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
        lastReload = Date()
        model.onCurrentLocation = { AlertNotifier.rememberCurrentLocation($0) }
        await model.refresh(place: places.selected)
        AlertNotifier.markSeen(model.alerts)
        // After a failed load, skip the widget reload and prefetch: more requests would only add to a 429.
        guard case .loaded(let f) = model.state else { return }
        if places.selected == nil { AlertNotifier.markRainSeen(f.nowcast()) }
        WidgetCenter.shared.reloadAllTimelines()
        // Warm up the saved places so the first switch to one is quick.
        Task { await model.prefetch(places.places) }
    }
}

private struct ForecastList: View {
    let forecast: Forecast
    let alerts: [WeatherAlert]
    let airQuality: AirQuality?
    var normals: ClimateNormals? = nil
    let placeName: String?
    let isSavedPlace: Bool
    let attribution: String
    let usingFallbackLocation: Bool
    var isRefreshing = false
    /// This phone's report the Now card is showing.
    var ownReport: ConditionReport? = nil
    /// nil hides the "What's it doing?" button (saved places, or no real location).
    var onReport: ((ReportKind) -> Void)? = nil
    var onUndoReport: () -> Void = {}
    @State private var showingReport = false
    @AppStorage(DisplaySettings.hourlyCountKey) private var hourlyCount = 24
    @AppStorage(DisplaySettings.showDetailsKey) private var showDetails = true
    @AppStorage(DisplaySettings.showAirQualityKey) private var showAirQuality = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad (and other wide windows): two columns side by side, each scrolling on its own.
    /// In Split View or Slide Over the window turns compact and goes back to one column.
    private var twoColumns: Bool { sizeClass == .regular }

    /// Short credit line; the full credits are one tap away.
    private var sourceNames: String {
        "Sources: " + Credits.shortNames(forecast: forecast, alerts: alerts).joined(separator: ", ")
    }

    /// The next hours, with "Now" showing the same temperature as the Now card
    /// (which may come from a nearby station rather than the forecast model).
    private var hoursStartingNow: [HourlyForecast] {
        forecast.hoursStartingNow(count: hourlyCount)
    }
    /// Daily rows as displayed: today's low is tonight's low, the same on every screen and the widget.
    private var days: [DailyForecast] { forecast.displayDaily() }
    private var todayDisplay: DailyForecast? { forecast.displayDay() }
    private var weekLow: Double { days.map(\.low).min() ?? 0 }
    private var weekHigh: Double { days.map(\.high).max() ?? 0 }
    /// Normals for this spot only (never the previous place's).
    private var localNormals: ClimateNormals? {
        guard let normals, normals.covers(forecast.location) else { return nil }
        return normals
    }
    private func normalHigh(_ day: DailyForecast) -> Double? {
        localNormals?.normal(for: day.date, timeZone: forecast.timeZone)?.high
    }
    /// "6° warmer than usual · normal high 7°" for today, from the same high as the chip.
    private var vsNormal: (text: String, trend: Int)? {
        guard let today = todayDisplay, let normal = normalHigh(today) else { return nil }
        return (NormalComparison.shortText(high: today.high, normalHigh: normal),
                NormalComparison.trend(high: today.high, normalHigh: normal))
    }

    var body: some View {
        Group {
            if twoColumns {
                HStack(alignment: .top, spacing: 0) {
                    column { nowSections; radarSection }
                    column { forecastSections }
                }
            } else {
                column { nowSections; forecastSections }
            }
        }
        .task(id: forecast.observation?.observedAt ?? forecast.fetchedAt) {
            // Keep score of the models for where the user actually is, not saved places.
            guard !isSavedPlace, !usingFallbackLocation else { return }
            await AccuracyTracker.update(location: forecast.location, timeZone: forecast.timeZone,
                                        observation: forecast.observation,
                                        shownTemperature: forecast.current.temperature)
        }
        .fontDesign(.rounded)
        .onAppear {
            // CI screenshots: "-showReportSheet YES" opens the sheet.
            if onReport != nil, UserDefaults.standard.bool(forKey: "showReportSheet") { showingReport = true }
        }
        .sheet(isPresented: $showingReport) {
            ReportSheet(isDay: forecast.current.isDay, current: ownReport?.kind) { kind in
                onReport?(kind)
                showingReport = false
            }
            .presentationDetents([.medium, .large])
            .tint(.blue)
        }
        .task(id: forecast.fetchedAt) {
            let storms = forecast.current.condition.isPrecipitation
                || forecast.current.condition == .thunderstorm
                || forecast.radar?.isPrecipitating == true
            let cold = forecast.current.temperature <= 3
            hazards = await RelayExtrasProvider().hazards(near: forecast.location, storms: storms, cold: cold)
        }
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .listSectionSpacing(14)
    }

    /// Live radar loop, with any storm heading this way.
    private var radarSection: some View {
        Section {
            NavigationLink {
                RadarMapView(center: forecast.location, timeZone: forecast.timeZone)
            } label: {
                RadarPreviewCard(center: forecast.location, timeZone: forecast.timeZone, refreshKey: forecast.fetchedAt)
            }
        } header: {
            SkySectionHeader(title: "Radar", systemImage: "dot.radiowaves.left.and.right")
        }
        .glassRow()
    }

    @State private var hazards: RelayHazards?

    /// Alerts, now, the next hours: the left column on iPad.
    @ViewBuilder private var nowSections: some View {
            if let banners = hazards?.banners, !banners.isEmpty {
                Section {
                    ForEach(banners) { b in
                        Label(b.text, systemImage: b.icon)
                            .font(.footnote.weight(.semibold))
                    }
                }
                .glassRow()
            }
            if usingFallbackLocation {
                Section {
                    Label("Location is off, so this shows Toronto. Turn on location in Settings for weather where you are.",
                          systemImage: "location.slash")
                        .font(.footnote)
                }
                .glassRow()
            }

            if Date().timeIntervalSince(forecast.fetchedAt) > 45 * 60 {
                Section {
                    Label(isRefreshing
                          ? "Updating. This is the forecast from \(TimeText.time(forecast.fetchedAt, forecast.timeZone))."
                          : "Couldn't refresh. This is the forecast from \(TimeText.time(forecast.fetchedAt, forecast.timeZone)); pull down to try again.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                }
                .glassRow()
            }

            if !alerts.isEmpty {
                Section {
                    ForEach(alerts) {
                        AlertBanner(alert: $0, timeZone: forecast.timeZone)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                }
            }

            Section {
                CurrentConditionsView(current: forecast.current, placeName: placeName, isSavedPlace: isSavedPlace,
                                      observation: forecast.observation, timeZone: forecast.timeZone,
                                      skySource: forecast.skySource,
                                      today: todayDisplay, outlook: Outlook.text(forecast, hourText: { TimeText.hour($0, forecast.timeZone) }),
                                      wear: WhatToWear.tip(current: forecast.current,
                                                           upcoming: Array(forecast.upcomingHours(count: 13).dropFirst()),
                                                           hourText: { TimeText.hour($0, forecast.timeZone) }),
                                      vsNormal: vsNormal,
                                      vsYesterday: forecast.changeSinceYesterday().map {
                                          (YesterdayComparison.shortText($0), YesterdayComparison.trend($0))
                                      },
                                      ownReport: ownReport,
                                      onReportTap: onReport == nil ? nil : { showingReport = true },
                                      onUndoReport: onUndoReport)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if let nowcast = forecast.nowcast() {
                Section {
                    NextTwoHoursView(nowcast: nowcast, slots: forecast.nowcastSlots())
                } header: {
                    SkySectionHeader(title: "Next 2 hours", systemImage: "umbrella")
                }
                .glassRow()
            }

            let parts = forecast.dayParts()
            if parts.count == 4 {
                Section {
                    DayPartsView(parts: parts)
                } header: {
                    SkySectionHeader(title: "Today and tonight", systemImage: "sun.and.horizon")
                }
                .glassRow()
            }

            Section {
                HourlyCurve(hours: hoursStartingNow, timeZone: forecast.timeZone)
                    // A new forecast starts the strip back at "now" instead of keeping an old scroll position.
                    .id(forecast.fetchedAt)
            } header: {
                SkySectionHeader(title: "Next \(hourlyCount) hours", systemImage: "clock")
            }
            .glassRow()
    }

    /// Days, details, air and sources: the right column on iPad.
    @ViewBuilder private var forecastSections: some View {
            Section {
                NavigationLink {
                    WeekendView(forecast: forecast)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max.fill")
                            .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.28))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Weekend forecast")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Fri–Sun · Morn / Aft / Eve / Night")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
            .glassRow()

            Section {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    NavigationLink {
                        DayDetailView(day: day, hours: forecast.displayHours(on: day), timeZone: forecast.timeZone,
                                      location: forecast.location, appDays: forecast.daily,
                                      normal: localNormals?.normal(for: day.date, timeZone: forecast.timeZone))
                    } label: {
                        DailyRow(day: day, isToday: index == 0, timeZone: forecast.timeZone,
                                 weekLow: weekLow, weekHigh: weekHigh,
                                 current: index == 0 ? forecast.current.temperature : nil,
                                 normalTrend: normalHigh(day).map { NormalComparison.trend(high: day.high, normalHigh: $0) })
                    }
                }
            } header: {
                SkySectionHeader(title: "\(forecast.daily.count)-day forecast", systemImage: "calendar")
            }
            .glassRow()

            if !twoColumns { radarSection }

            if showDetails {
                Section {
                    TodayDetailsView(forecast: forecast)
                } header: {
                    SkySectionHeader(title: "Today", systemImage: "sun.horizon")
                }
                .glassRow()
            }

            if showAirQuality, let airQuality, (airQuality.usAQI != nil || airQuality.aqhi != nil) {
                Section {
                    AirQualityView(air: airQuality)
                } header: {
                    SkySectionHeader(title: "Air quality", systemImage: "aqi.medium")
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
}

/// One day in the 10-day list: weekday, icon, chance of rain or snow, and the low-to-high bar.
struct DailyRow: View {
    let day: DailyForecast
    let isToday: Bool
    let timeZone: TimeZone
    let weekLow: Double
    let weekHigh: Double
    var current: Double?
    /// +1 above normal, -1 below, 0 or nil: no arrow.
    var normalTrend: Int? = nil

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
                if let confidence = day.confidence {
                    ConfidenceMark(confidence: confidence)
                }
            }
            .frame(width: 62, alignment: .leading)
            VStack(spacing: 1) {
                IconBadge(condition: day.condition, size: 34, heavy: (day.rainSum ?? 0) >= 12, mixed: day.isMixedPrecipitation)
                PrecipChance(probability: day.precipitationProbability, kind: day.precipitationKind,
                             font: .caption2.weight(.semibold), showsIcon: false)
            }
            .frame(width: 40)
            HStack(spacing: 1) {
                if let normalTrend, normalTrend != 0 {
                    Image(systemName: normalTrend > 0 ? "arrow.up" : "arrow.down")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(normalTrend > 0 ? Brand.gold : Color(red: 0.62, green: 0.84, blue: 1))
                        .accessibilityLabel(normalTrend > 0 ? "Above normal" : "Below normal")
                }
                Text(WeatherFormat.temperature(day.high))
                    .font(.body.weight(.semibold))
            }
            .frame(width: 46, alignment: .trailing)
            TemperatureRangeBar(low: day.low, high: day.high, weekLow: weekLow, weekHigh: weekHigh, current: current)
            Text(WeatherFormat.temperature(day.low))
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
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
    /// Where the sky (rain, cloud) came from; nil means the forecast.
    var skySource: String? = nil
    var today: DailyForecast? = nil
    /// "Cooling to 1° by 11 PM."
    var outlook: String? = nil
    /// "Warm jacket, and an umbrella from 1 PM."
    var wear: String? = nil
    /// "6° warmer than usual · normal high 7°", and +1/-1/0 for the icon.
    var vsNormal: (text: String, trend: Int)? = nil
    /// "5° colder than yesterday at this time", and +1/-1/0 for the icon.
    var vsYesterday: (text: String, trend: Int)? = nil
    /// This phone's report the card is showing, for "You said Raining · Undo".
    var ownReport: ConditionReport? = nil
    /// nil hides the "What's it doing?" button.
    var onReportTap: (() -> Void)? = nil
    var onUndoReport: () -> Void = {}
    @AppStorage(DisplaySettings.mainTemperatureKey) private var mainTemperature = MainTemperature.actual.rawValue

    private var feelsFirst: Bool { mainTemperature == MainTemperature.feelsLike.rawValue }

    private var feelsText: String {
        if feelsFirst {
            return "\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)). Actual \(WeatherFormat.temperature(current.temperature))"
        }
        return "\(WeatherFormat.feelsLikeLabel(current.feelsLikeKind)) \(WeatherFormat.temperature(current.feelsLike))"
    }

    private var factChips: some View {
        HStack(alignment: .center, spacing: 8) {
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
            if let wear {
                Label {
                    Text(wear).font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "tshirt.fill").foregroundStyle(Brand.gold)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // Against normal and against yesterday share one line, to keep the card short.
            let comparisons = [vsNormal, vsYesterday].compactMap { $0 }
            if let first = comparisons.first {
                Label {
                    Text(comparisons.map(\.text).joined(separator: " · ")).font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: first.trend > 0 ? "thermometer.sun.fill"
                          : first.trend < 0 ? "thermometer.snowflake" : "thermometer.medium")
                        .foregroundStyle(Brand.gold)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // In one row when they fit; on a narrow phone or with large text, a row that scrolls.
            ViewThatFits(in: .horizontal) {
                factChips
                ScrollView(.horizontal, showsIndicators: false) { factChips }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let observation, observation.isLocal {
                    Text(Self.localCaption(observation, timeZone: timeZone)
                         + " Sky from \(skySource ?? "the forecast").")
                } else if observation != nil || skySource != nil {
                    Text("Sky from \(skySource ?? "the forecast"). Temperature is the forecast for your spot.")
                } else {
                    Text("Model estimate (no nearby station)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.88))
            if let onReportTap {
                reportRow(onReportTap)
            }
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

    /// "Wrong? Tell us what it's doing", or, after a report, what you said and an undo.
    @ViewBuilder private func reportRow(_ tap: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: tap) {
                Label(ownReport == nil ? "What's it doing outside?" : "Changed? Report again",
                      systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.22)))
                    .overlay(Capsule().stroke(Brand.gold.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain)
            if ownReport != nil {
                Button("Undo", action: onUndoReport)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.gold)
            }
            Spacer(minLength: 0)
        }
    }

    /// "Temperature from 3 home weather stations about 3 km away, 4:55 am."
    static func localCaption(_ o: Observation, timeZone: TimeZone) -> String {
        "Temperature from \(WeatherFormat.readingSource(o)), \(TimeText.time(o.observedAt, timeZone))."
    }
}

/// A compact grid of today's extra numbers under the current conditions.
struct TodayDetailsView: View {
    let forecast: Forecast

    private struct Tile: Identifiable {
        let title: String
        let value: String
        let systemImage: String
        /// One short line on what the number means.
        var note: String = ""
        /// Small arrow after the value (pressure trend).
        var trendImage: String? = nil
        var id: String { title }
    }

    private var tiles: [Tile] {
        let now = forecast.current
        let hour = forecast.hour()
        let day = forecast.day()
        let tz = forecast.timeZone
        var list: [Tile] = []
        func add(_ title: String, _ value: String?, _ image: String, note: String = "", trend: String? = nil) {
            if let value { list.append(Tile(title: title, value: value, systemImage: image, note: note, trendImage: trend)) }
        }
        // The rest of today's hours, for when to wear sunscreen.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let restOfToday = forecast.upcomingHours(count: 24).filter { calendar.isDate($0.time, inSameDayAs: Date()) }
        add("UV index", WeatherFormat.uvLevel(hour?.uvIndex), "sun.max.fill",
            note: DetailNotes.uv(hours: restOfToday, hourText: { TimeText.hour($0, tz) }))
        if let gusts = now.windGusts ?? hour?.windGusts {
            var text = WeatherFormat.wind(gusts)
            if let dir = WeatherFormat.compass(now.windDirection) { text = "\(dir), \(text)" }
            add("Gusts", text, "wind", note: DetailNotes.gusts(gusts: gusts, wind: now.windSpeed))
        }
        let trend = forecast.pressureTrend()
        add("Pressure", WeatherFormat.pressure(now.pressure ?? hour?.pressure), "gauge.with.dots.needle.33percent",
            note: trend?.note ?? "", trend: trend?.symbolName)
        if let humidity = now.humidity ?? hour?.humidity {
            add("Humidity", WeatherFormat.percent(humidity), "humidity.fill",
                note: DetailNotes.humidity(dewPoint: hour?.dewPoint))
        }
        if let km = hour?.visibility.map({ $0 / 1000 }) {
            add("Visibility", WeatherFormat.distance(km), "eye", note: DetailNotes.visibility(km: km))
        }
        if let sunrise = day?.sunrise, let sunset = day?.sunset {
            let mins = Int(sunset.timeIntervalSince(sunrise) / 60)
            add("Daylight", "\(mins / 60) hr \(mins % 60) min", "sun.max",
                note: "Sunset \(TimeText.time(sunset, tz)).")
        }
        if let day, day.rainSum != nil || day.snowfallSum != nil {
            let today = WeatherFormat.precipitationTotals(rainMm: day.rainSum, snowCm: day.snowfallSum) ?? "None"
            let weekTotals = forecast.precipitationTotals(days: 7)
            let week = weekTotals.map {
                WeatherFormat.precipitationTotals(rainMm: $0.rainMm, snowCm: $0.snowCm) ?? "none"
            }
            let r = day.rainSum ?? 0, s = day.snowfallSum ?? 0
            let icon: String
            if r > 0 && s > 0 {
                icon = "cloud.sleet.fill"
            } else if s > 0 {
                icon = "snowflake"
            } else if r > 0 {
                icon = "drop.fill"
            } else if let w = weekTotals, w.rainMm > 0 && w.snowCm > 0 {
                icon = "cloud.sleet.fill"
            } else if let w = weekTotals, w.snowCm > 0 {
                icon = "snowflake"
            } else if let w = weekTotals, w.rainMm > 0 {
                icon = "drop.fill"
            } else {
                icon = "cloud.sleet.fill"
            }
            add("Rain and snow today", today, icon, note: week.map { "Next 7 days: \($0)." } ?? "")
        }
        return list
    }

    var body: some View {
        VStack(spacing: 10) {
            if let day = forecast.day(), let rise = day.sunrise, let set = day.sunset {
                SunArcView(sunrise: rise, sunset: set, timeZone: forecast.timeZone)
            }
            MoonRow(date: Date(), timeZone: forecast.timeZone)
            grid
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 4) {
                    Label(tile.title, systemImage: tile.systemImage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                    HStack(spacing: 4) {
                        Text(tile.value)
                            .font(.body.weight(.semibold))
                        if let trend = tile.trendImage {
                            Image(systemName: trend)
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Brand.gold)
                        }
                    }
                    if !tile.note.isEmpty {
                        Text(tile.note)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Three small bars: all gold when the models agree on the day, one when they don't.
struct ConfidenceMark: View {
    let confidence: ForecastConfidence

    private var filled: Int {
        switch confidence {
        case .sure: return 3
        case .fair: return 2
        case .unsure: return 1
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i < filled ? Brand.gold : .white.opacity(0.25))
                    .frame(width: 7, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(confidence.label)
    }
}

/// "What's it doing outside?": one tap corrects the Now card here, on family phones nearby and in
/// the widget, and gives the learner a ground truth the radar can't (drizzle under the beam).
struct ReportSheet: View {
    var isDay: Bool
    /// What this phone last said, highlighted.
    var current: ReportKind?
    var onPick: (ReportKind) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tap what you see. The Now card uses it for the next 45 minutes, and family nearby see it too.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(ReportKind.shown) { kind in
                            Button { onPick(kind) } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: kind.condition.symbolName(isDay: isDay))
                                        .symbolRenderingMode(.multicolor)
                                        .font(.system(size: 30))
                                        .frame(height: 36)
                                    Text(kind.label(isDay: isDay))
                                        .font(.footnote.weight(.semibold))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity, minHeight: 84)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(kind == current ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.1)))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(kind == current ? Color.blue : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(kind.label(isDay: isDay))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("What's it doing now?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
