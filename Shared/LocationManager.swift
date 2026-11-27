import CoreLocation
import WeatherCore

/// One-shot location lookups for the iPhone/iPad app.
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

    /// Last cached fix when already authorized, without waiting for a new GPS wake-up.
    var cachedCoordinate: Coordinate? {
        let s = manager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return nil }
        let c = manager.location.map(Self.coordinate)
        remember(c)
        return c
    }

    /// Where the phone was at the last fix, kept across launches. Right after a cold launch iOS often
    /// has no `manager.location` yet, and a fresh fix can take from seconds to minutes indoors; the
    /// app waited for it, showing the old forecast with "Couldn't refresh" meanwhile (26 Nov, 11 pm).
    /// Loading for the last known spot straight away, then checking the fresh fix, avoids that.
    static let lastFixKey = "lastLocationFix"

    var lastKnownCoordinate: Coordinate? {
        let s = manager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways,
              let a = UserDefaults.standard.array(forKey: Self.lastFixKey) as? [Double], a.count == 2 else { return nil }
        return Coordinate(latitude: a[0], longitude: a[1])
    }

    private func remember(_ c: Coordinate?) {
        guard let c else { return }
        UserDefaults.standard.set([c.latitude, c.longitude], forKey: Self.lastFixKey)
    }

    /// Longest wait for a fix; after that, the last position iOS knows (or nil).
    static let fixTimeout: TimeInterval = 10

    /// Asks for permission if needed, then returns the current position, or nil if unavailable.
    func currentCoordinate() async -> Coordinate? {
        if pending != nil { return manager.location.map(Self.coordinate) }
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fixTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.pending != nil,
                  self.manager.authorizationStatus != .notDetermined else { return }
            self.finish(self.manager.location.map(Self.coordinate))
        }
        defer { deadline.cancel() }
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
        remember(coordinate)
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
