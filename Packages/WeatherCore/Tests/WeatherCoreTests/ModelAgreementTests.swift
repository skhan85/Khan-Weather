import XCTest
@testable import WeatherCore

final class ModelAgreementTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_000_000)

    func hour(_ offset: Int, temp: Double, count: Int?, wet: Int = 0, freezing: Int = 0) -> HourlyForecast {
        var h = HourlyForecast(time: now.addingTimeInterval(Double(offset) * 3600), temperature: temp, condition: .overcast)
        h.modelCount = count
        h.modelsWet = count == nil ? nil : wet
        h.modelsFreezing = count == nil ? nil : freezing
        return h
    }

    func forecast(_ hours: [HourlyForecast], currentTemp: Double = 4) -> Forecast {
        Forecast(location: .fallback, timeZoneIdentifier: "America/Toronto",
                 current: CurrentConditions(time: now, temperature: currentTemp, feelsLike: currentTemp,
                                            feelsLikeKind: .apparent, condition: .overcast, isDay: false),
                 hourly: hours, daily: [], source: "t", fetchedAt: now)
    }

    func testWetNeedsHalfTheModels() {
        XCTAssertTrue(ModelAgreement.wetAgrees([hour(1, temp: 5, count: 7, wet: 4)], now: now))
        XCTAssertFalse(ModelAgreement.wetAgrees([hour(1, temp: 5, count: 7, wet: 2)], now: now))
        XCTAssertTrue(ModelAgreement.wetAgrees([hour(1, temp: 5, count: nil)], now: now), "no counts: don't block")
    }

    func testFrostWhenMostModelsFreeze() throws {
        let f = forecast([hour(3, temp: 2, count: 7, freezing: 2), hour(8, temp: 0, count: 7, freezing: 6)])
        let frost = try XCTUnwrap(ModelAgreement.frost(f, now: now))
        XCTAssertEqual(frost.agreeing, 6)
        XCTAssertEqual(frost.time, now.addingTimeInterval(8 * 3600))
        XCTAssertNil(ModelAgreement.frost(forecast([hour(8, temp: 1, count: 7, freezing: 3)]), now: now))
        XCTAssertNil(ModelAgreement.frost(forecast([hour(8, temp: 0, count: 7, freezing: 7)], currentTemp: -1), now: now),
                     "already freezing")
    }
}
