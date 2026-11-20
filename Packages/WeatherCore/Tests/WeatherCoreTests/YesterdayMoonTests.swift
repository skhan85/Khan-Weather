import XCTest
@testable import WeatherCore

final class YesterdayMoonTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_762_956_000) // 2025-11-12 9 AM Toronto

    private func hour(_ offset: Double, _ temp: Double, pressure: Double? = nil) -> HourlyForecast {
        var h = HourlyForecast(time: now.addingTimeInterval(offset * 3600), temperature: temp, condition: .clear)
        h.pressure = pressure
        return h
    }

    private func forecast(hourly: [HourlyForecast], recent: [HourlyForecast]?) -> Forecast {
        var f = Forecast(location: .fallback, timeZoneIdentifier: "America/Toronto",
                         current: CurrentConditions(time: now, temperature: 9, feelsLike: 9, feelsLikeKind: .apparent,
                                                    condition: .clear, isDay: true),
                         hourly: hourly, daily: [], source: "test", fetchedAt: now)
        f.recentHours = recent
        return f
    }

    func testChangeSinceYesterdayUsesSameModelHours() throws {
        let f = forecast(hourly: [hour(0, 20)], recent: [hour(-24, 8), hour(-23, 8.5), hour(0, 3)])
        // The blended hourly value (20) is ignored; recent hours compare 3 with 8.
        XCTAssertEqual(try XCTUnwrap(f.changeSinceYesterday(at: now.addingTimeInterval(600))), -5, accuracy: 0.001)
        XCTAssertNil(forecast(hourly: [], recent: nil).changeSinceYesterday(at: now))
    }

    func testYesterdayText() {
        XCTAssertEqual(YesterdayComparison.text(-5.2, unit: .celsius), "5° colder than yesterday at this time")
        XCTAssertEqual(YesterdayComparison.text(3.6, unit: .celsius), "4° warmer than yesterday at this time")
        XCTAssertEqual(YesterdayComparison.text(1.2, unit: .celsius), "About the same as yesterday at this time")
        XCTAssertEqual(YesterdayComparison.trend(1.2, unit: .celsius), 0)
        // 1.2 °C is 2 °F, which is worth saying in Fahrenheit.
        XCTAssertEqual(YesterdayComparison.text(1.2, unit: .fahrenheit), "2° warmer than yesterday at this time")
    }

    func testPressureTrend() {
        let f = forecast(hourly: [hour(0, 5, pressure: 1008)], recent: [hour(-3, 5, pressure: 1012), hour(0, 5, pressure: 1008)])
        XCTAssertEqual(f.pressureTrend(at: now), .falling(fast: true))
        XCTAssertEqual(PressureTrend.from(change: 0.4), .steady)
        XCTAssertEqual(PressureTrend.from(change: 1.5), .rising(fast: false))
    }

    func testParseSplitsOffYesterday() throws {
        let json = """
        {"latitude": 43.65, "longitude": -79.38, "timezone": "America/Toronto",
         "current": {"time": 1762956000, "temperature_2m": 3},
         "hourly": {"time": [1762869600, 1762952400, 1762956000],
                    "temperature_2m": [8, 2, 3], "pressure_msl": [1012, 1010, 1009]},
         "daily": {"time": [1762837200, 1762923600], "temperature_2m_max": [9, 5], "temperature_2m_min": [1, 0]}}
        """.data(using: .utf8)!
        let f = try OpenMeteoProvider.parse(json, fetchedAt: now)
        XCTAssertEqual(f.hourly.map(\.temperature), [2, 3])
        XCTAssertEqual(f.recentHours?.count, 3)
        XCTAssertEqual(f.daily.map(\.high), [5])
        XCTAssertEqual(f.hourly.last?.pressure, 1009)
        XCTAssertEqual(try XCTUnwrap(f.changeSinceYesterday(at: now)), -5, accuracy: 0.001)
        let url = OpenMeteoProvider().url(for: .fallback).absoluteString
        XCTAssertTrue(url.contains("past_days=1"))
        XCTAssertTrue(url.contains("pressure_msl"))
    }

    func testMoonPhase() {
        // Full moon 2025-11-05 13:19 UTC; new moon 2025-11-20 06:47 UTC.
        let full = MoonPhase(date: Date(timeIntervalSince1970: 1_762_348_740))
        XCTAssertEqual(full.name, "Full moon")
        XCTAssertGreaterThan(full.illumination, 0.97)
        let new = MoonPhase(date: Date(timeIntervalSince1970: 1_763_621_220))
        XCTAssertEqual(new.name, "New moon")
        XCTAssertLessThan(new.illumination, 0.03)
        let next = new.nextFullMoon(after: Date(timeIntervalSince1970: 1_763_621_220))
        // 2025-12-04 23:14 UTC, within a day.
        XCTAssertEqual(next.timeIntervalSince1970, 1_764_890_040, accuracy: 86_400)
    }

    func testDetailNotes() {
        XCTAssertEqual(DetailNotes.visibility(km: 0.5), "Fog. Drive slowly with low beams.")
        XCTAssertEqual(DetailNotes.visibility(km: 24), "Clear view.")
        var a = hour(0, 5); a.uvIndex = 1
        var b = hour(1, 5); b.uvIndex = 4
        var c = hour(2, 5); c.uvIndex = 3
        var d = hour(3, 5); d.uvIndex = 1
        let text = DetailNotes.uv(hours: [a, b, c, d], hourText: { "\(Int($0.timeIntervalSince(self.now) / 3600))h" })
        XCTAssertEqual(text, "Use sun protection from 1h to 3h.")
        XCTAssertEqual(DetailNotes.uv(hours: [a, d], hourText: { _ in "" }), "Low for the rest of the day.")
    }

    func testWeekTotals() throws {
        var f = forecast(hourly: [], recent: nil)
        f.daily = (0..<8).map { i in
            DailyForecast(date: now.addingTimeInterval(Double(i) * 86_400 - 9 * 3600), high: 5, low: 0,
                          condition: .rain, rainSum: 2, snowfallSum: i == 1 ? 3 : 0)
        }
        let t = try XCTUnwrap(f.precipitationTotals(days: 7, at: now))
        XCTAssertEqual(t.rainMm, 14, accuracy: 0.001)
        XCTAssertEqual(t.snowCm, 3, accuracy: 0.001)
    }
}
