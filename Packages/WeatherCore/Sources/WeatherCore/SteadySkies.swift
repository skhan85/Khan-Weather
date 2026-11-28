import Foundation

public extension WeatherCondition {
    /// Dry skies from clearest to cloudiest; nil for fog, rain, snow and storms.
    var cloudRank: Int? {
        switch self {
        case .clear: return 0
        case .mainlyClear: return 1
        case .partlyCloudy: return 2
        case .mostlyCloudy: return 3
        case .overcast: return 4
        default: return nil
        }
    }

    static let skiesByCloud: [WeatherCondition] = [.clear, .mainlyClear, .partlyCloudy, .mostlyCloudy, .overcast]
}

public extension Forecast {
    /// One hour whose sky jumps two or more steps from both neighbours, the same way, is pulled
    /// one step short of them. 28 Nov, Milton: the model saw ~10% cloud at 11 am alone, so the
    /// hourly row went Overcast, Clear, Overcast under a grey sky. It now reads Mostly cloudy: the
    /// break the model saw, without the sunny icon. Rain, snow and fog hours are left alone.
    func withSteadySkies() -> Forecast {
        guard hourly.count >= 3 else { return self }
        var copy = self
        for i in 1..<(hourly.count - 1) {
            guard let r = hourly[i].condition.cloudRank,
                  let a = hourly[i - 1].condition.cloudRank,
                  let b = hourly[i + 1].condition.cloudRank else { continue }
            if a >= r + 2 && b >= r + 2 {
                copy.hourly[i].condition = WeatherCondition.skiesByCloud[min(a, b) - 1]
            } else if a <= r - 2 && b <= r - 2 {
                copy.hourly[i].condition = WeatherCondition.skiesByCloud[max(a, b) + 1]
            }
        }
        return copy
    }
}
