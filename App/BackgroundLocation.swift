import CoreLocation
import UIKit
import WeatherCore

/// Extra background wake-ups for notifications. iOS wakes (or relaunches) an app that watches
/// significant location changes (about 500 m or more) and visits (arriving at or leaving a place),
/// even when it isn't running. Each wake also keeps "your location" fresh for alerts. Needs
/// location access set to Always; it uses the low-power cell/Wi-Fi location, not GPS.
final class BackgroundLocation: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocation()

    private let manager = CLLocationManager()
    private var lastCheck: Date?
    /// Don't run the full check more than this often, however much the phone moves.
    private let minimumGap: TimeInterval = 10 * 60

    private override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// Called at every launch, including a background relaunch for a location event: the system
    /// delivers the event to a manager that has a delegate, so this must run early.
    func start() {
        guard AlertNotifier.anyEnabled else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
            return
        }
        guard manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
    }

    /// Asks to upgrade "While Using" to "Always". iOS shows this prompt once; after that the
    /// person changes it in the Settings app.
    func requestAlways() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestAlwaysAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        start()
        NotificationCenter.default.post(name: .locationAuthorizationChanged, object: nil)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        wake(at: location.coordinate, reason: "location change")
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        wake(at: visit.coordinate, reason: "arrived or left a place")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func wake(at c: CLLocationCoordinate2D, reason: String) {
        guard CLLocationCoordinate2DIsValid(c) else { return }
        AlertNotifier.rememberCurrentLocation(Coordinate(latitude: c.latitude, longitude: c.longitude))
        if let lastCheck, Date().timeIntervalSince(lastCheck) < minimumGap { return }
        lastCheck = Date()
        // A location wake gives about 10 seconds; ask for a little more so the checks can finish.
        Task { @MainActor in
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
            await AlertNotifier.checkAll(reason: reason)
            AlertNotifier.schedule()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}

extension Notification.Name {
    static let locationAuthorizationChanged = Notification.Name("locationAuthorizationChanged")
}
