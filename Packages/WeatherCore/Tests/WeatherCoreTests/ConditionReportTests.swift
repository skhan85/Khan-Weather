import XCTest
@testable import WeatherCore

/// "What's it doing now?" reports (28 Nov 2026, after the card said "Overcast" while it drizzled).
final class ConditionReportTests: XCTestCase {
    static let milton = Coordinate(latitude: 43.513, longitude: -79.882)

    func forecast(_ condition: WeatherCondition = .overcast) -> Forecast {
        let now = Date()
        let current = CurrentConditions(time: now, temperature: 5, feelsLike: 3, feelsLikeKind: .apparent,
                                        humidity: 92, condition: condition, isDay: false)
        var f = Forecast(location: Self.milton, timeZoneIdentifier: "America/Toronto", current: current,
                         hourly: [], daily: [], source: "t", fetchedAt: now)
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 900).rounded(.down) * 900)
        f.minutely = (0..<8).map { PrecipitationSlot(time: start.addingTimeInterval(Double($0) * 900), precipitation: 0) }
        f.observation = Observation(stationName: "3 Netatmo stations", observedAt: now, temperature: 5, distanceKm: 2)
        return f
    }

    func testOwnReportSetsCardAndNextTwoHours() {
        let now = Date()
        let r = ConditionReport(kind: .drizzle, time: now.addingTimeInterval(-300), at: Self.milton)
        let shown = forecast().applyingReports([r], now: now)
        XCTAssertEqual(shown.current.condition, .drizzle)
        XCTAssertEqual(shown.observation?.conditionText, "Drizzle")
        XCTAssertEqual(shown.skySource, "your report, 5 min ago")
        XCTAssertEqual(shown.nowcast(at: now)?.kind, .rain, "Next 2 hours agrees with the card")
        XCTAssertEqual(shown.current.temperature, 5, "temperature is left alone")
    }

    func testDryReportClearsRain() {
        let now = Date()
        var f = forecast(.rain)
        f.minutely[0] = PrecipitationSlot(time: f.minutely[0].time, precipitation: 0.5, rain: 0.5)
        let shown = f.applyingReports([ConditionReport(kind: .cloudy, time: now, at: Self.milton)], now: now)
        XCTAssertEqual(shown.current.condition, .overcast)
        XCTAssertEqual(shown.observation?.conditionText, "Cloudy")
        XCTAssertNil(shown.radar)
        XCTAssertFalse(shown.minutely[0].isWet)
    }

    func testReportsExpireAndStayLocal() {
        let now = Date()
        let old = ConditionReport(kind: .rain, time: now.addingTimeInterval(-50 * 60), at: Self.milton)
        XCTAssertEqual(forecast().applyingReports([old], now: now).current.condition, .overcast, "own report lasts 45 min")
        let oakville = Coordinate(latitude: 43.45, longitude: -79.68)
        let far = ConditionReport(kind: .rain, time: now, at: oakville)
        XCTAssertEqual(forecast().applyingReports([far], now: now).current.condition, .overcast, "17 km away doesn't count")
        let neighbour = ConditionReport(kind: .snow, time: now.addingTimeInterval(-20 * 60),
                                        at: Coordinate(latitude: 43.54, longitude: -79.88), mine: false)
        let shown = forecast().applyingReports([neighbour], now: now)
        XCTAssertEqual(shown.current.condition, .snow)
        XCTAssertTrue(shown.skySource?.hasPrefix("someone's report") == true)
        let stale = ConditionReport(kind: .snow, time: now.addingTimeInterval(-46 * 60),
                                    at: Self.milton, mine: false)
        XCTAssertEqual(forecast().applyingReports([stale], now: now).current.condition, .overcast, "same 45 min for everyone")
    }

    func testNewestReportWins() {
        let now = Date()
        let a = ConditionReport(kind: .rain, time: now.addingTimeInterval(-20 * 60), at: Self.milton)
        let b = ConditionReport(kind: .partlyCloudy, time: now.addingTimeInterval(-2 * 60), at: Self.milton, mine: false)
        XCTAssertEqual(forecast().applyingReports([a, b], now: now).current.condition, .partlyCloudy)
    }

    func testMergeDoesNotDoubleCountOwnReport() {
        let r = ConditionReport(kind: .rain, at: Self.milton)
        var echo = r
        echo.mine = false
        XCTAssertEqual(ConditionReportStore.merged(mine: [r], relay: [echo]).count, 1)
    }

    func testEveryKindHasMatchingWetness() {
        for k in ReportKind.allCases {
            XCTAssertEqual(k.isWet, k.slot.rain + k.slot.snow > 0, "\(k)")
        }
        XCTAssertEqual(Set(ReportKind.shown), Set(ReportKind.allCases))
    }
}
