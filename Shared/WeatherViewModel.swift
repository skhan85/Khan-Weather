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

    /// The place the last forecast was for: nil for the current location.
    private var lastPlaceID: UUID?? = .none

    /// Loads the forecast for `place`, or for the current location when it is nil.
    func refresh(place: SavedPlace? = nil) async {
        // Switching places: don't leave the old place's forecast on screen while loading.
        if lastPlaceID != .some(place?.id) {
            state = .loading
            alerts = []
            lastPlaceID = .some(place?.id)
        }
        let target: Coordinate
        if let place {
            target = place.coordinate
            usingFallbackLocation = false
        } else {
            let coordinate = await location.currentCoordinate()
            usingFallbackLocation = coordinate == nil
            target = coordinate ?? .fallback
        }
        async let name = Self.name(for: place, at: target)
        // Station observations are a bonus: if they fail, the model's "now" is still shown.
        async let observed = try? observations.observation(near: target)
        async let activeAlerts = try? alertProvider.alerts(near: target)
        async let radarNow = try? ECCCRadarProvider().now(at: target)
        do {
            let forecast = try await provider.forecast(for: target).applying(await observed ?? nil)
                .applyingRadar(await radarNow)
            placeName = await name ?? (usingFallbackLocation ? "Toronto" : nil)
            // If the alert service didn't answer, keep the last list for this place rather than hide a warning.
            if let fresh = await activeAlerts { alerts = fresh }
            state = .loaded(forecast)
        } catch {
            // Keep showing the last good forecast if we have one.
            if case .loaded = state { return }
            state = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func name(for place: SavedPlace?, at target: Coordinate) async -> String? {
        if let place { return place.name }
        return await PlaceNameResolver.name(for: target)
    }
}
