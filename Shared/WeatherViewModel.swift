import Foundation
import WeatherCore

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
    /// Environment Canada's written forecast, in Canada.
    @Published private(set) var textForecast: TextForecast?

    let provider: ForecastProvider
    let observations: ObservationProvider
    let alertProvider: AlertProvider
    private let location: LocationManager

    init(provider: ForecastProvider = OpenMeteoProvider(),
         observations: ObservationProvider = HyperlocalObservationProvider(),
         alertProvider: AlertProvider = WorldAlertProvider(),
         location: LocationManager? = nil) {
        self.provider = provider
        self.observations = observations
        self.alertProvider = alertProvider
        self.location = location ?? LocationManager()
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
        var textForecast: TextForecast? = nil
        var at: Date
    }
    private var cache: [UUID?: Snapshot] = [:]
    /// Older than this, a cached forecast isn't shown while switching.
    private let cacheAge: TimeInterval = 45 * 60

    /// Loads the forecast for `place`, or for the current location when it is nil.
    ///
    /// The Open-Meteo forecast is shown as soon as it arrives; the station reading, radar, alerts and
    /// air quality are filled in as each one answers, so one slow service doesn't hold up the screen.
    func refresh(place: SavedPlace? = nil) async {
        generation += 1
        let gen = generation
        let key = place?.id
        // Switching places: show what we had for the new place, or a spinner, never the old place.
        if lastPlaceID != .some(key) {
            lastPlaceID = .some(key)
            if let snap = cache[key], Date().timeIntervalSince(snap.at) < cacheAge {
                state = .loaded(snap.forecast)
                placeName = snap.name
                alerts = snap.alerts
                airQuality = snap.airQuality
                textForecast = snap.textForecast
            } else {
                state = .loading
                placeName = place?.name
                alerts = []
                airQuality = nil
                textForecast = nil
            }
        }
        let target: Coordinate
        if let place {
            target = place.coordinate
            usingFallbackLocation = false
        } else {
            let coordinate = await location.currentCoordinate()
            guard gen == generation else { return }
            usingFallbackLocation = coordinate == nil
            if let coordinate { onCurrentLocation?(coordinate) }
            target = coordinate ?? .fallback
        }
        let fallbackName = usingFallbackLocation ? "Toronto" : nil
        let provider = self.provider, observations = self.observations, alertProvider = self.alertProvider

        // Everything starts at once.
        let nameTask = Task { await Self.name(for: place, at: target) }
        let observedTask = Task { try? await observations.observation(near: target) }
        let radarTask = Task { try? await ECCCRadarProvider().now(at: target) }
        let alertsTask = Task { try? await alertProvider.alerts(near: target) }
        let airTask = Task { try? await AirQualityProvider().airQuality(at: target) }
        let textTask = Task { try? await TextForecastProvider().forecast(near: target) }

        let base: Forecast
        do {
            base = try await provider.forecast(for: target)
        } catch {
            guard gen == generation else { return }
            // Keep showing the last good forecast if we have one.
            if case .loaded = state { return }
            state = .failed(error.localizedDescription)
            return
        }
        guard gen == generation else { return }
        // First paint: the model forecast, unless a fuller one for this place is already on screen.
        if case .loaded = state {} else { state = .loaded(base) }

        // The rest land in whatever order they answer.
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
                guard let fresh = await textTask.value, gen == self.generation else { return }
                self.textForecast = fresh
            }
            group.addTask { @MainActor in
                let observed = await observedTask.value ?? nil
                let radar = await radarTask.value ?? nil
                guard gen == self.generation else { return }
                self.state = .loaded(base.applying(observed).applyingRadar(radar))
            }
        }
        guard gen == generation, case .loaded(let shown) = state else { return }
        cache[key] = Snapshot(forecast: shown, name: placeName, alerts: alerts, airQuality: airQuality,
                              textForecast: textForecast, at: Date())
    }

    /// Fetches saved places in the background so the first switch to each one is instant.
    func prefetch(_ places: [SavedPlace]) async {
        for place in places {
            if let snap = cache[place.id], Date().timeIntervalSince(snap.at) < cacheAge / 2 { continue }
            let target = place.coordinate
            let provider = self.provider, observations = self.observations, alertProvider = self.alertProvider
            async let forecast = try? provider.forecast(for: target)
            async let observed = try? observations.observation(near: target)
            async let radar = try? ECCCRadarProvider().now(at: target)
            async let fetchedAlerts = try? alertProvider.alerts(near: target)
            async let air = try? AirQualityProvider().airQuality(at: target)
            async let text = try? TextForecastProvider().forecast(near: target)
            guard let base = await forecast else { continue }
            let full = base.applying(await observed ?? nil).applyingRadar(await radar ?? nil)
            let snap = Snapshot(forecast: full, name: place.name, alerts: await fetchedAlerts ?? [],
                                airQuality: await air, textForecast: await text ?? nil, at: Date())
            // Don't overwrite a fresher entry from a refresh that ran meanwhile.
            if let existing = cache[place.id], existing.at > snap.at { continue }
            cache[place.id] = snap
        }
    }

    private nonisolated static func name(for place: SavedPlace?, at target: Coordinate) async -> String? {
        if let place { return place.name }
        return await PlaceNameResolver.name(for: target)
    }
}
