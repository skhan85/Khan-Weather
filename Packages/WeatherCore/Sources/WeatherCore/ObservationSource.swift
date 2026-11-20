import Foundation

/// Which observation provider the app and widget use, so both pick it the same way.
public enum ObservationSource {
    /// The app's Settings switch for Netatmo home stations (through the relay).
    public static let hyperlocalKey = "useHyperlocalPWS"
    /// On unless turned off, in the app and the widget alike: the widget can't read the app's
    /// settings, so both must start from the same choice to show the same "now".
    public static let hyperlocalDefault = true

    /// The app's setting, or the default when it was never changed.
    public static func usesHyperlocal(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hyperlocalKey) as? Bool ?? hyperlocalDefault
    }

    public static func provider(hyperlocal: Bool) -> ObservationProvider {
        hyperlocal ? HyperlocalObservationProvider() : WorldObservationProvider()
    }
}

public extension Observation {
    /// The temperature that may re-weight the first hours of the model blend: only a reading
    /// close enough to stand in for this spot. A station 25-40 km away is used for the sky only
    /// (see `Forecast.applying`), so it mustn't steer the models either.
    var blendAnchor: ModelBlend.Anchor? {
        guard isLocal, temperature.isFinite else { return nil }
        return ModelBlend.Anchor(temperature: temperature, time: observedAt)
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
