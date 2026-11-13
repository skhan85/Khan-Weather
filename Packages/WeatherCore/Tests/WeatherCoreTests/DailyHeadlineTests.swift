import XCTest
@testable import WeatherCore

final class DailyHeadlineTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/Toronto")!

    private func time(_ hour: Int) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        return c.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: hour))!
    }

    private func hour(_ h: Int, _ temp: Double, _ condition: WeatherCondition,
                      rain: Double = 0, snow: Double = 0) -> HourlyForecast {
        var x = HourlyForecast(time: time(h), temperature: temp, precipitation: rain + snow * 0.7,
                               condition: condition, isDay: (7...16).contains(h))
        x.rain = rain
        x.snowfall = snow
        return x
    }

    private func forecast(_ day: DailyForecast, _ hours: [HourlyForecast]) -> Forecast {
        Forecast(location: Coordinate(latitude: 43.5, longitude: -79.9), timeZoneIdentifier: tz.identifier,
                 current: CurrentConditions(time: time(12), temperature: 10, feelsLike: 10, feelsLikeKind: .apparent,
                                            humidity: nil, windSpeed: nil, windDirection: nil,
                                            precipitation: nil, condition: .overcast, isDay: true),
                 hourly: hours, daily: [day], source: "test", fetchedAt: time(0))
    }

    func testLowChanceFlurryOnMildDayShowsSky() {
        // 13° by day, a brief flurry at 23:00 as it drops below zero, 16% chance: the Nov 22 case.
        var hours = (0..<23).map { hour($0, $0 < 18 ? 12 : 4, $0 < 12 ? .partlyCloudy : .overcast) }
        hours.append(hour(23, -1, .snow, snow: 0.2))
        let day = DailyForecast(date: time(0), high: 13, low: -2, precipitationProbability: 16, condition: .snow,
                                rainSum: 0, snowfallSum: 0.2)
        let d = forecast(day, hours).withDailyHeadlines().daily[0]
        XCTAssertFalse(d.condition.isPrecipitation)
        XCTAssertNil(d.summary)
    }

    func testRainThenSnow() {
        var hours = (0..<24).map { hour($0, 8, .overcast) }
        hours[14] = hour(14, 9, .rain, rain: 1.2)
        hours[15] = hour(15, 7, .rain, rain: 0.8)
        hours[16] = hour(16, 4, .rain, rain: 0.4)
        hours[21] = hour(21, 0, .snow, snow: 0.3)
        let day = DailyForecast(date: time(0), high: 10, low: -1, precipitationProbability: 70, condition: .snow,
                                rainSum: 2.4, snowfallSum: 0.3)
        let d = forecast(day, hours).withDailyHeadlines().daily[0]
        XCTAssertEqual(d.summary, "Rain then snow")
        XCTAssertEqual(d.condition, .rain)
    }

    func testAllRainDayFlaggedSnowBecomesRain() {
        var hours = (0..<24).map { hour($0, 8, .overcast) }
        hours[10] = hour(10, 9, .rain, rain: 2)
        let day = DailyForecast(date: time(0), high: 10, low: 5, precipitationProbability: 80, condition: .snow)
        let d = forecast(day, hours).withDailyHeadlines().daily[0]
        XCTAssertEqual(d.condition, .rain)
        XCTAssertNil(d.summary)
    }

    func testRealSnowDayUnchanged() {
        var hours = (0..<24).map { hour($0, -3, .overcast) }
        for h in 8...15 { hours[h] = hour(h, -2, .snow, snow: 0.8) }
        let day = DailyForecast(date: time(0), high: -1, low: -6, precipitationProbability: 90, condition: .snow)
        let d = forecast(day, hours).withDailyHeadlines().daily[0]
        XCTAssertEqual(d.condition, .snow)
        XCTAssertNil(d.summary)
    }
}
