import Foundation

/// Which observation provider the app and widget use, so both pick it the same way.
public enum ObservationSource {
    /// The app's Settings switch for Netatmo home stations (through the relay).
    public static let hyperlocalKey = "useHyperlocalPWS"

    public static func provider(hyperlocal: Bool) -> ObservationProvider {
        hyperlocal ? HyperlocalObservationProvider() : WorldObservationProvider()
    }
}

public extension Observation {
    /// The temperature that may re-weight the first hours of the model blend: only a reading
    /// close enough to stand in for this spot. A station 25-40 km away is used for the sky only
    /// (see `Forecast.applying`), so it mustn't steer the models either.
    var blendAnchor: Double? {
        guard isLocal, temperature.isFinite else { return nil }
        return temperature
    }
}

public enum Deadline {
    /// Runs `operation`, giving up with nil after `seconds`. The operation is cancelled then,
    /// which stops a URLSession request.
    public static func run<T: Sendable>(_ seconds: Double,
                                        _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
