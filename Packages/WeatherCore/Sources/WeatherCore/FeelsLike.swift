import Foundation

/// One "feels like" rule for every screen: Environment Canada's. Wind chill at 10° or colder in
/// a breeze, humidex at 20° or warmer when it's muggy enough to add a degree, otherwise the air
/// temperature.
///
/// Station readings already use it (`Forecast.applying(_:)`), but the hourly list, the day
/// screen and a "now" without a station used Open-Meteo's apparent temperature, a different
/// formula: on a humid 25° day it says about 27° where humidex says 32°, and in a winter breeze
/// it runs a degree off wind chill. So the Now card and the next hour could disagree on "feels".
public enum FeelsLike {
    /// The value and its kind, or nil when there's no wind or humidity to judge by.
    public static func value(temperature t: Double, windKmh: Double?,
                             dewPoint: Double?) -> (value: Double, kind: FeelsLikeKind)? {
        guard windKmh != nil || dewPoint != nil else { return nil }
        if let chill = EnvironmentCanadaProvider.windChill(temperature: t, windKmh: windKmh) {
            return (chill, .windChill)
        }
        if let hx = EnvironmentCanadaProvider.humidex(temperature: t, dewpoint: dewPoint) {
            return (hx, .humidex)
        }
        return (t, .apparent)
    }

    /// Magnus dew point (°C) from temperature (°C) and relative humidity (%).
    static func dewPoint(temperature t: Double, humidity rh: Double?) -> Double? {
        guard let rh else { return nil }
        let a = 17.625, b = 243.04
        let gamma = log(min(100, max(1, rh)) / 100) + (a * t) / (b + t)
        return min(t, (b * gamma) / (a - gamma))
    }
}

extension Forecast {
    /// Recomputes "feels like" for now, each hour and each fully covered day with `FeelsLike`.
    /// Hours without wind or humidity keep the provider's value.
    func withStandardFeelsLike() -> Forecast {
        var copy = self
        if let f = FeelsLike.value(temperature: current.temperature, windKmh: current.windSpeed,
                                   dewPoint: FeelsLike.dewPoint(temperature: current.temperature,
                                                                humidity: current.humidity)) {
            copy.current.feelsLike = f.value
            copy.current.feelsLikeKind = f.kind
        }
        copy.hourly = hourly.map { hour in
            var h = hour
            let dew = h.dewPoint ?? FeelsLike.dewPoint(temperature: h.temperature, humidity: h.humidity)
            if let f = FeelsLike.value(temperature: h.temperature, windKmh: h.windSpeed, dewPoint: dew) {
                h.feelsLike = f.value
            }
            return h
        }
        copy.daily = daily.map { day in
            var d = day
            let hours = copy.hours(on: day)
            let feels = hours.compactMap(\.feelsLike)
            guard hours.count >= 18, feels.count == hours.count else { return d }
            d.feelsLikeHigh = feels.max()
            d.feelsLikeLow = feels.min()
            return d
        }
        return copy
    }
}
