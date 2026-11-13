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

    let provider: ForecastProvider
    let observations: ObservationProvider
    private let location: LocationManager

    init(provider: ForecastProvider = OpenMeteoProvider(),
         observations: ObservationProvider = CanadaObservationProvider(),
         location: LocationManager? = nil) {
        self.provider = provider
        self.observations = observations
        self.location = location ?? LocationManager()
    }

    func refresh() async {
        let coordinate = await location.currentCoordinate()
        usingFallbackLocation = coordinate == nil
        let target = coordinate ?? .fallback
        async let name = PlaceNameResolver.name(for: target)
        // Station observations are a bonus: if they fail, the model's "now" is still shown.
        async let observed = try? observations.observation(near: target)
        do {
            let forecast = try await provider.forecast(for: target).applying(await observed ?? nil)
            placeName = await name ?? (usingFallbackLocation ? "Toronto" : nil)
            state = .loaded(forecast)
        } catch {
            // Keep showing the last good forecast if we have one.
            if case .loaded = state { return }
            state = .failed(error.localizedDescription)
        }
    }
}
