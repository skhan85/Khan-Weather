import Foundation
import WeatherCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Loads the forecast for the user's location. Used by the iPhone/iPad app.
@MainActor
final class WeatherViewModel: ObservableObject {
    enum State {
        case loading
        case loaded(Forecast)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// True when location was unavailable and the fallback city is shown.
    @Published private(set) var usingFallbackLocation = false
    /// Town or city name for the forecast location, e.g. "Mississauga".
    @Published private(set) var placeName: String?

    /// Active alerts covering the forecast spot, most serious first.
    @Published private(set) var alerts: [WeatherAlert] = []
    /// Air quality and pollen at the forecast spot; nil if the service didn't answer.
    @Published private(set) var airQuality: AirQuality?
    /// 1991–2020 normal highs and lows near the forecast spot, for "warmer than usual". Screens
    /// check `covers(_:)`, so normals for the previous place are never shown for a new one.
    @Published private(set) var normals: ClimateNormals?

    let provider: ForecastProvider
    let observations: ObservationProvider
    let alertProvider: AlertProvider
    private let location: LocationManager

    init(provider: ForecastProvider = OpenMeteoProvider(),
         observations: ObservationProvider = WorldObservationProvider(),
         alertProvider: AlertProvider = WorldAlertProvider(),
         location: LocationManager? = nil) {
        self.provider = provider
        self.observations = observations
        self.alertProvider = alertProvider
        self.location = location ?? LocationManager()
    }

    /// The last station reading shown, by spot (rounded to ~1 km), to steady the next one.
    private var lastObservation: [String: Observation] = [:]

    private static func spotKey(_ c: Coordinate) -> String {
        String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    /// Called with each real current-location fix (the app uses it for background alert checks).
    var onCurrentLocation: ((Coordinate) -> Void)?

    /// The place the last forecast was for: nil for the current location.
    private var lastPlaceID: UUID?? = .none
    /// Bumped by each refresh, so a slow answer for the previous place can't overwrite the new one.
    private var generation = 0

    /// What was last shown for each place, so switching back shows it at once while it refreshes.
    private struct Snapshot {
        var forecast: Forecast
        var name: String?
        var alerts: [WeatherAlert]
        var airQuality: AirQuality?
        var at: Date
    }
    private var cache: [UUID?: Snapshot] = [:]
    /// Older than this, a cached forecast isn't shown while switching.
    private let cacheAge: TimeInterval = 45 * 60
    /// The last good forecast per place, kept as a file in Caches (a 10-day forecast is too big
    /// for UserDefaults, which loads whole at launch). Shown when loading fails, for up to 6 hours.
    private static func diskCacheURL(_ key: UUID?) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("forecast-\(key?.uuidString ?? "current").json")
    }

    private static func saveDiskCache(_ forecast: Forecast, for key: UUID?) {
        guard let url = diskCacheURL(key), let data = try? JSONEncoder().encode(forecast) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadDiskCache(for key: UUID?, maxAge: TimeInterval = 6 * 3600) -> Forecast? {
        guard let url = diskCacheURL(key), let data = try? Data(contentsOf: url),
              let forecast = try? JSONDecoder().decode(Forecast.self, from: data),
              Date().timeIntervalSince(forecast.fetchedAt) < maxAge else { return nil }
        return forecast
    }

    /// Clears the copies the first version kept in UserDefaults.
    private static let dropOldDiskCache: Void = {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("forecastCache-") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }()

    /// Loads the forecast for `place`, or for the current location when it is nil.
    ///
    /// The Open-Meteo forecast is shown as soon as it arrives; the station reading, radar, alerts and
    /// air quality are filled in as each one answers, so one slow service doesn't hold up the screen.
    func refresh(place: SavedPlace? = nil) async {
        await load(place: place, allowLocationFollowUp: true)
    }

    private func load(place: SavedPlace?, allowLocationFollowUp: Bool) async {
        _ = Self.dropOldDiskCache
        generation += 1
        let gen = generation
        let key = place?.id
        // Switching places or cold-launching: show what we had for this place, or a spinner.
        var showingStaleDiskCache = false
        if lastPlaceID != .some(key) {
            lastPlaceID = .some(key)
            if let snap = cache[key], Date().timeIntervalSince(snap.at) < cacheAge {
                // Saved forecasts were calibrated before saving; calibrating again would push rain chances up.
                state = .loaded(snap.forecast)
                placeName = snap.name
                alerts = snap.alerts
                airQuality = snap.airQuality
            } else if let cached = Self.loadDiskCache(for: key, maxAge: 2 * 3600) {
                let shown = Date().timeIntervalSince(cached.fetchedAt) < cacheAge ? cached : cached.rolledForward()
                state = .loaded(shown)
                showingStaleDiskCache = true
                placeName = place?.name
                alerts = []
                airQuality = nil
            } else {
                state = .loading
                placeName = place?.name
                alerts = []
                airQuality = nil
            }
        }
        let target: Coordinate
        let freshCoordTask: Task<Coordinate?, Never>?
        if let place {
            target = place.coordinate
            usingFallbackLocation = false
            freshCoordTask = nil
        } else if let cached = location.cachedCoordinate {
            target = cached
            usingFallbackLocation = false
            onCurrentLocation?(cached)
            let loc = self.location
            freshCoordTask = allowLocationFollowUp ? Task { await loc.currentCoordinate() } : nil
        } else {
            let coordinate = await location.currentCoordinate()
            guard gen == generation else { return }
            usingFallbackLocation = coordinate == nil
            if let coordinate { onCurrentLocation?(coordinate) }
            target = coordinate ?? .fallback
            freshCoordTask = nil
        }
        let fallbackName = usingFallbackLocation ? "Toronto" : nil
        let provider = self.provider, alertProvider = self.alertProvider
        let observations = currentObservationProvider()
        let spot = Self.spotKey(target)
        let previous = lastObservation[spot]
        let knownTemp = previous?.temperature ?? cache[key]?.forecast.current.temperature
        let likelyCold = knownTemp.map { $0 <= 4 } ?? (abs(target.latitude) >= 25)

        // Everything starts at once. Cap the anchor wait inside OpenMeteoProvider at 1.5s so slow
        // stations never stall the initial forecast, while `observedTask` finishes up to 5s total.
        let nameTask = Task { await Self.name(for: place, at: target) }
        let observedTask = Task {
            await Deadline.run(5) { try? await observations.observation(near: target) }?
                .smoothed(after: previous)
        }
        let radarTask = Task { try? await ECCCRadarProvider().now(at: target) }
        let nowcastTask = Task { await RelayExtrasProvider().nowcast(near: target, cold: likelyCold) }
        let weightsTask = Task { await Deadline.run(3) { await RelayExtrasProvider().regionalWeights(near: target) } }
        let googleTask = Task { await Deadline.run(3) { await RelayExtrasProvider().googleHourly(near: target) } }
        let mosmixTask = Task { await Deadline.run(2.5) { await RelayExtrasProvider().mosmixHourly(near: target) } }
        let alertsTask = Task { try? await alertProvider.alerts(near: target) }
        let airTask = Task { try? await AirQualityProvider().airQuality(at: target) }
        let normalsTask = Task { try? await ClimateNormalsProvider().normals(at: target) }

        let base: Forecast
        do {
            if let om = provider as? OpenMeteoProvider {
                base = try await om.forecast(
                    for: target,
                    anchor: { await Deadline.run(1.5) { await observedTask.value?.blendAnchor } },
                    regionalWeights: { await weightsTask.value }
                )
            } else {
                base = try await provider.forecast(for: target)
            }
        } catch {
            guard gen == generation else { return }
            // Keep showing the last good forecast if we have one.
            if case .loaded = state { return }
            if let cached = Self.loadDiskCache(for: key) {
                state = .loaded(cached.rolledForward())
                return
            }
            state = .failed(error.localizedDescription)
            return
        }
        guard gen == generation else { return }
        // First paint: show model forecast immediately (always replacing stale cold disk cache).
        if case .loaded = state, !showingStaleDiskCache {} else {
            state = .loaded(base.calibratingEnsemblePop())
        }

        // Apply station reading as soon as it arrives—without waiting on radar, nowcast, or Google.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                let name = await nameTask.value ?? fallbackName
                guard gen == self.generation else { return }
                if name != nil || self.placeName == nil { self.placeName = name }
            }
            group.addTask { @MainActor in
                // If the alert service didn't answer, keep the last list for this place rather than hide a warning.
                guard let fresh = await alertsTask.value, gen == self.generation else { return }
                self.alerts = fresh
            }
            group.addTask { @MainActor in
                guard let fresh = await airTask.value, gen == self.generation else { return }
                self.airQuality = fresh
            }
            group.addTask { @MainActor in
                guard let fresh = await normalsTask.value, gen == self.generation else { return }
                self.normals = fresh
            }
            group.addTask { @MainActor in
                let observed = await observedTask.value
                guard gen == self.generation else { return }
                if let observed {
                    self.lastObservation[spot] = observed
                    self.state = .loaded(base.applying(observed).calibratingEnsemblePop())
                }
                let googleHourly = await googleTask.value
                let mosmixHourly = await mosmixTask.value
                guard gen == self.generation else { return }
                if googleHourly != nil || mosmixHourly != nil {
                    self.state = .loaded(base.applyingMosmixHourly(mosmixHourly).applyingGoogleHourly(googleHourly).applying(observed).calibratingEnsemblePop())
                }
                let radar = await radarTask.value ?? nil
                let radarNowcast = await nowcastTask.value
                guard gen == self.generation else { return }
                self.state = .loaded(base.applyingMosmixHourly(mosmixHourly).applyingGoogleHourly(googleHourly).applying(observed).applyingRadar(radar).applyingRadarNowcast(radarNowcast).calibratingEnsemblePop())
            }
        }
        guard gen == generation, case .loaded(let shown) = state else { return }
        cache[key] = Snapshot(forecast: shown, name: placeName, alerts: alerts, airQuality: airQuality, at: Date())
        #if canImport(WidgetKit)
        if place == nil { WidgetCenter.shared.reloadAllTimelines() }
        #endif
        Self.saveDiskCache(shown, for: key)

        if let fresh = await freshCoordTask?.value, gen == generation {
            onCurrentLocation?(fresh)
            if EnvironmentCanadaProvider.distanceKm(target, fresh) > 1.5 {
                await load(place: nil, allowLocationFollowUp: false)
            }
        }
    }

    /// Fetches saved places in the background so the first switch to each one is instant.
    func prefetch(_ places: [SavedPlace]) async {
        for place in places.prefix(3) {
            if let snap = cache[place.id], Date().timeIntervalSince(snap.at) < cacheAge / 2 { continue }
            try? await Task.sleep(nanoseconds: 600_000_000)
            let target = place.coordinate
            let spot = Self.spotKey(target)
            let knownTemp = lastObservation[spot]?.temperature ?? cache[place.id]?.forecast.current.temperature
            let likelyCold = knownTemp.map { $0 <= 4 } ?? (abs(target.latitude) >= 25)
            let provider = self.provider, alertProvider = self.alertProvider
            let observations = currentObservationProvider()
            async let observed = Deadline.run(8) { try? await observations.observation(near: target) }
            async let radar = try? ECCCRadarProvider().now(at: target)
            async let nowcast = RelayExtrasProvider().nowcast(near: target, cold: likelyCold)
            let weightsTask = Task { await Deadline.run(3) { await RelayExtrasProvider().regionalWeights(near: target) } }
            async let googleHourly = Deadline.run(3) { await RelayExtrasProvider().googleHourly(near: target) }
            async let mosmixHourly = Deadline.run(2.5) { await RelayExtrasProvider().mosmixHourly(near: target) }
            async let fetchedAlerts = try? alertProvider.alerts(near: target)
            async let air = try? AirQualityProvider().airQuality(at: target)
            let obs = await observed
            let base: Forecast?
            if let om = provider as? OpenMeteoProvider {
                base = try? await om.forecast(
                    for: target,
                    anchor: { obs?.blendAnchor },
                    regionalWeights: { await weightsTask.value }
                )
            } else {
                base = try? await provider.forecast(for: target)
            }
            guard let base else { continue }
            let full = base.applyingMosmixHourly(await mosmixHourly).applyingGoogleHourly(await googleHourly).applying(obs).applyingRadar(await radar ?? nil)
                .applyingRadarNowcast(await nowcast).calibratingEnsemblePop()
            let snap = Snapshot(forecast: full, name: place.name, alerts: await fetchedAlerts ?? [],
                                airQuality: await air, at: Date())
            // Don't overwrite a fresher entry from a refresh that ran meanwhile.
            if let existing = cache[place.id], existing.at > snap.at { continue }
            cache[place.id] = snap
        }
    }

    /// Netatmo home stations through the relay when Settings has them on, otherwise official stations.
    private func currentObservationProvider() -> ObservationProvider {
        ObservationSource.usesHyperlocal()
            ? ObservationSource.provider(hyperlocal: true) : observations
    }

    private nonisolated static func name(for place: SavedPlace?, at target: Coordinate) async -> String? {
        if let place { return place.name }
        return await PlaceNameResolver.name(for: target)
    }
}
