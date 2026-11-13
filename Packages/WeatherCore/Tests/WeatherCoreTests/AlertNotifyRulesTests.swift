import XCTest
@testable import WeatherCore

final class AlertNotifyRulesTests: XCTestCase {
    func testImplausibleNetatmoKeepsOnlySky() {
        let now = Date()
        let current = CurrentConditions(time: now, temperature: 3, feelsLike: 0, feelsLikeKind: .apparent,
                                        condition: .overcast, isDay: true)
        let f = Forecast(location: Coordinate(latitude: 43.5, longitude: -79.9), timeZoneIdentifier: "America/Toronto",
                         current: current, hourly: [], daily: [], source: "t", fetchedAt: now)
        var o = Observation(stationName: "Netatmo", observedAt: now, temperature: 10, distanceKm: 1)
        o.dataProvider = "NETATMO"
        XCTAssertEqual(f.applying(o).current.temperature, 3)
        o.temperature = 5
        XCTAssertEqual(f.applying(o).current.temperature, 5)
    }
}
