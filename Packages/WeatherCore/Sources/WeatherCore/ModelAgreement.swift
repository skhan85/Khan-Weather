import Foundation

/// Heads-ups that fire only when most of the blended models agree.
public enum ModelAgreement {
    /// True when at least half the models have rain or snow in one of the next `hours` hours,
    /// or when there are no model counts to go on (outside North America).
    public static func wetAgrees(_ hourly: [HourlyForecast], now: Date = Date(), hours: Int = 2) -> Bool {
        let window = hourly.filter { $0.time.addingTimeInterval(3600) > now && $0.time < now.addingTimeInterval(Double(hours) * 3600) }
        let counted = window.compactMap { h -> Double? in
            guard let n = h.modelCount, n > 0, let wet = h.modelsWet else { return nil }
            return Double(wet) / Double(n)
        }
        guard let best = counted.max() else { return true }
        return best >= 0.5
    }

    public struct Frost: Equatable, Sendable {
        public var agreeing: Int
        public var total: Int
        public var time: Date
    }

    /// Frost tonight: most models (60 % or more, at least 3) at or below 0 °C at some hour in the
    /// next `hours`. nil if it's already freezing now or too few models agree.
    public static func frost(_ forecast: Forecast, now: Date = Date(), hours: Int = 16) -> Frost? {
        guard forecast.current.temperature > 0.5 else { return nil }
        let window = forecast.hourly.filter { $0.time > now && $0.time <= now.addingTimeInterval(Double(hours) * 3600) }
        var best: Frost?
        for h in window {
            guard let n = h.modelCount, n >= 3, let cold = h.modelsFreezing,
                  Double(cold) >= (Double(n) * 0.6).rounded(.up) else { continue }
            if best == nil || Double(cold) / Double(n) > Double(best!.agreeing) / Double(best!.total) {
                best = Frost(agreeing: cold, total: n, time: h.time)
            }
        }
        return best
    }
}
