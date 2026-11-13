import XCTest
@testable import WeatherCore

final class NowcastTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_762_956_000)

    /// A forecast whose 15-minute slots start at `start` with the given (precipitation mm, snowfall cm).
    func forecast(_ slots: [(Double, Double)]) -> Forecast {
        let current = CurrentConditions(time: start, temperature: 1, feelsLike: 1, feelsLikeKind: .apparent,
                                        condition: .overcast, isDay: true)
        let minutely = slots.enumerated().map { i, s in
            PrecipitationSlot(time: start.addingTimeInterval(Double(i) * 900), precipitation: s.0,
                              rain: s.1 > 0 ? 0 : s.0, snowfall: s.1)
        }
        return Forecast(location: Coordinate(latitude: 43.5, longitude: -79.9), timeZoneIdentifier: "America/Toronto",
                        current: current, hourly: [], daily: [], source: "test", fetchedAt: start, minutely: minutely)
    }

    func testRainStarting() {
        let f = forecast([(0, 0), (0, 0), (0.4, 0), (0.8, 0), (0, 0)])
        let n = f.nowcast(at: start.addingTimeInterval(5 * 60))
        XCTAssertEqual(n, Nowcast(kind: .rain, change: .starting(minutes: 25)))
        XCTAssertEqual(n?.text, "Rain starting in about 25 min")
    }

    func testSnowStopping() {
        let f = forecast([(0.3, 0.2), (0.3, 0.2), (0.3, 0.2), (0.3, 0.2), (0.3, 0.2), (0, 0)])
        let n = f.nowcast(at: start)
        XCTAssertEqual(n, Nowcast(kind: .snow, change: .stopping(minutes: 75)))
        XCTAssertEqual(n?.text, "Snow stopping in about 1 hr 15 min")
    }

    func testContinuing() {
        let f = forecast(Array(repeating: (0.5, 0), count: 12))
        XCTAssertEqual(f.nowcast(at: start)?.change, .continuing)
    }

    func testDryOrStaleIsNil() {
        XCTAssertNil(forecast(Array(repeating: (0.0, 0.0), count: 12)).nowcast(at: start))
        XCTAssertNil(forecast([(0.05, 0)]).nowcast(at: start), "trace amounts count as dry")
        // Data that starts after "now" is from a different request; don't guess.
        XCTAssertNil(forecast([(0, 0), (1, 0)]).nowcast(at: start.addingTimeInterval(-3600)))
        // Rain more than 2 hours out is the hourly forecast's job.
        let late = forecast(Array(repeating: (0.0, 0.0), count: 9) + [(1, 0)])
        XCTAssertNil(late.nowcast(at: start))
    }

    func testDailyTotalsFormat() {
        XCTAssertEqual(WeatherFormat.precipitationTotals(rainMm: 3.4, snowCm: 0), "3 mm")
        XCTAssertEqual(WeatherFormat.precipitationTotals(rainMm: 0.6, snowCm: 2.2), "2 cm, 1 mm")
        XCTAssertNil(WeatherFormat.precipitationTotals(rainMm: 0.2, snowCm: nil))
    }
}
