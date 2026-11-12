import CoreLocation
import WeatherCore

/// One-shot location lookups for the iPhone/iPad app and the Watch app.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<Coordinate?, Never>?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters // hyperlocal, without draining battery
    }

    /// Asks for permission if needed, then returns the current position, or nil if unavailable.
    func currentCoordinate() async -> Coordinate? {
        if pending != nil { return manager.location.map(Self.coordinate) }
        return await withCheckedContinuation { continuation in
            pending = continuation
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(nil)
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ coordinate: Coordinate?) {
        pending?.resume(returning: coordinate)
        pending = nil
    }

    nonisolated private static func coordinate(_ location: CLLocation) -> Coordinate {
        Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            guard self.pending != nil else { return }
            switch status {
            case .notDetermined: break
            case .denied, .restricted: self.finish(nil)
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last.map(Self.coordinate)
        Task { @MainActor in self.finish(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let fallback = manager.location.map(Self.coordinate)
        Task { @MainActor in self.finish(fallback) }
    }
}
