import XCTest
@testable import WeatherCore

final class SteadySkiesTests: XCTestCase {
    func forecast(_ skies: [WeatherCondition]) -> Forecast {
        let start = Date(timeIntervalSince1970: 1_795_870_800)
        let hours = skies.enumerated().map { i, c in
            HourlyForecast(time: start.addingTimeInterval(Double(i) * 3600), temperature: 7, condition: c, isDay: true)
        }
        return Forecast(location: Coordinate(latitude: 43.51, longitude: -79.88), timeZoneIdentifier: "America/Toronto",
                        current: CurrentConditions(time: start, temperature: 7, feelsLike: 4, feelsLikeKind: .apparent, condition: .overcast, isDay: true),
                        hourly: hours, daily: [], source: "test", fetchedAt: start)
    }

    func testLoneClearHourUnderCloudBecomesMostlyCloudy() {
        let out = forecast([.overcast, .overcast, .clear, .overcast, .overcast]).withSteadySkies()
        XCTAssertEqual(out.hourly.map(\.condition), [.overcast, .overcast, .mostlyCloudy, .overcast, .overcast])
    }

    func testLoneOvercastHourInSunshineSoftens() {
        let out = forecast([.clear, .overcast, .clear]).withSteadySkies()
        XCTAssertEqual(out.hourly[1].condition, .mainlyClear)
    }

    func testRealChangesAndRainAreKept() {
        let skies: [WeatherCondition] = [.overcast, .clear, .clear, .rain, .clear, .overcast, .mostlyCloudy, .overcast]
        XCTAssertEqual(forecast(skies).withSteadySkies().hourly.map(\.condition), skies)
    }

    func testMostlyCloudyText() {
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Mostly Cloudy"), .mostlyCloudy)
        XCTAssertEqual(WeatherCondition(metarWeather: nil, cover: "BKN"), .mostlyCloudy)
        XCTAssertEqual(WeatherCondition(metarWeather: nil, cover: "SCT"), .partlyCloudy)
        XCTAssertEqual(WeatherCondition.mostlyCloudy.description, "Mostly cloudy")
    }
}
