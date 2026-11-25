import XCTest
@testable import WeatherCore

/// Today's low, the blend anchor and the accuracy fallback: the pieces every screen and the widget share.
final class DisplayConsistencyTests: XCTestCase {
    let toronto = TimeZone(identifier: "America/Toronto")!

    /// Midnight, 19 Nov 2026, Toronto.
    var midnight: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = toronto
        return c.date(from: DateComponents(year: 2026, month: 11, day: 19))!
    }

    /// Hourly temperatures from midnight on the 19th for 48 hours: `temp(hoursFromMidnight)`.
    func forecast(_ temp: (Int) -> Double) -> Forecast {
        let hours = (0..<48).map { h in
            HourlyForecast(time: midnight.addingTimeInterval(Double(h) * 3600), temperature: temp(h), condition: .overcast)
        }
        let current = CurrentConditions(time: midnight, temperature: temp(0), feelsLike: temp(0),
                                        feelsLikeKind: .apparent, condition: .overcast, isDay: false)
        let days = [
            DailyForecast(date: midnight, high: 10, low: -3, condition: .overcast),
            DailyForecast(date: midnight.addingTimeInterval(86400), high: 8, low: 1, condition: .overcast),
        ]
        return Forecast(location: Coordinate(latitude: 43.5, longitude: -79.9), timeZoneIdentifier: "America/Toronto",
                        current: current, hourly: hours, daily: days, source: "test", fetchedAt: midnight)
    }

    func testBlendedHighAndLowIncludeTheBetweenHoursPeak() {
        // A full blended day: warmest hour 9.0 at 2 PM, coldest 1.0 at 6 AM.
        var f = forecast { h in h == 14 ? 9 : (h == 6 ? 1 : 5) }
        var temps = OpenMeteoProvider.ModelTemperatures()
        for h in f.hourly {
            temps.hourly[Int(h.time.timeIntervalSince1970)] = .init(temperature: h.temperature, feelsLike: nil,
                                                                    low: h.temperature, high: h.temperature,
                                                                    count: 6, wet: 0, freezing: 0)
        }
        f = f.applying(temps)
        XCTAssertEqual(f.daily[0].high, 9.4, accuracy: 0.001)
        XCTAssertEqual(f.daily[0].low, 0.5, accuracy: 0.001)
        // Tonight's low on the Now card gets the same allowance (coldest hour tonight is 5.0).
        let threePM = midnight.addingTimeInterval(15 * 3600)
        XCTAssertEqual(try XCTUnwrap(f.displayDay(at: threePM)?.low), 4.5, accuracy: 0.001)
    }

    func testTonightLowInTheEvening() {
        // Coldest at 5 AM on the 19th (-3), then 2 at 6 AM on the 20th.
        let f = forecast { h in h == 5 ? -3 : (h == 30 ? 2 : 6) }
        let threePM = midnight.addingTimeInterval(15 * 3600)
        XCTAssertEqual(f.tonightLow(from: threePM), 2)
        XCTAssertEqual(f.displayDay(at: threePM)?.low, 2)
        XCTAssertEqual(f.displayDaily(at: threePM).first?.low, 2)
        // Tomorrow keeps its own low.
        XCTAssertEqual(f.displayDaily(at: threePM)[1].low, 1)
    }

    func testTonightBeforeDawnIsTheNightWeAreIn() {
        let f = forecast { h in h == 5 ? -3 : (h == 30 ? 2 : 6) }
        let twoAM = midnight.addingTimeInterval(2 * 3600)
        XCTAssertEqual(f.tonightLow(from: twoAM), -3)
        XCTAssertEqual(f.displayDay(at: twoAM)?.low, -3)
    }

    func testDisplayLowNeverAboveHigh() {
        let f = forecast { _ in 14 }
        let noon = midnight.addingTimeInterval(12 * 3600)
        XCTAssertEqual(f.displayDay(at: noon)?.low, 10)
    }

    /// At 9 AM when it is -3° outside and tonight stays at 1°, Today's low stays at -3° instead of jumping to 1°.
    func testColdMorningLowIncludesCurrentTemperature() {
        var f = forecast { h in h <= 9 ? -3 : (h == 14 ? 3 : 1) }
        let nineAM = midnight.addingTimeInterval(9 * 3600)
        f.current.time = nineAM
        f.current.temperature = -3
        XCTAssertEqual(f.tonightLow(from: nineAM), 1)
        XCTAssertEqual(f.displayDay(at: nineAM)?.low, -3)
    }

    func testBlendAnchorOnlyForLocalStations() {
        let near = Observation(stationName: "Campbellville", observedAt: midnight, temperature: 4, distanceKm: 6)
        let far = Observation(stationName: "Toronto Pearson", observedAt: midnight, temperature: 7, distanceKm: 28)
        XCTAssertEqual(near.blendAnchor, ModelBlend.Anchor(temperature: 4, time: midnight))
        XCTAssertNil(far.blendAnchor)
    }

    func testLocalRangeNeedsTheNightAndAFullDayOfWaiting() {
        var r = AccuracyLog.LocalRange(day: "2026-11-17", temperature: 2, station: "Milton", isNight: true)
        for t in [5.0, 8, 9, 7, 4] { r.add(t, station: "Milton", isNight: false) }
        XCTAssertEqual(r.low, 2)
        XCTAssertEqual(r.high, 9)
        // The next morning the climate station may still post: wait.
        XCTAssertFalse(r.usable(today: "2026-11-18"))
        XCTAssertTrue(r.usable(today: "2026-11-19"))

        // Afternoon looks only: never stands in for the day's low.
        var afternoon = AccuracyLog.LocalRange(day: "2026-11-17", temperature: 8, station: "Milton", isNight: false)
        for t in [9.0, 9, 8, 7, 7] { afternoon.add(t, station: "Milton", isNight: false) }
        XCTAssertFalse(afternoon.usable(today: "2026-11-20"))
    }

    func testDayOffset() {
        XCTAssertEqual(AccuracyLog.day("2026-11-01", offsetBy: -1), "2026-10-31")
        XCTAssertNil(AccuracyLog.day("not a day", offsetBy: 1))
    }

    func testHoursStartingNowIsConsistentAcrossSliceLengthsAndDisplayHours() {
        // Blip at hour 19 (index 19 from midnight) sits right on the 19-hour Outlook boundary.
        let f = forecast { h in (18...22).contains(h) ? (h == 19 ? 6.5 : 6.4) : Double(h % 12) }
        let atMidnight = midnight.addingTimeInterval(300)
        var f2 = f
        f2.current.time = atMidnight
        f2.current.temperature = 0.0
        let h19 = f2.hoursStartingNow(from: atMidnight, count: 19)
        let h24 = f2.hoursStartingNow(from: atMidnight, count: 24)
        let h48 = f2.hoursStartingNow(from: atMidnight, count: 48)
        XCTAssertEqual(h19.map(\.temperature), Array(h24.prefix(19)).map(\.temperature))
        XCTAssertEqual(h24.map(\.temperature), Array(h48.prefix(24)).map(\.temperature))
        let dayHours = f2.displayHours(on: f2.daily[0], at: atMidnight)
        XCTAssertEqual(dayHours.count, 24)
        XCTAssertEqual(dayHours[0].temperature, 0.0)
        XCTAssertEqual(dayHours[19].temperature, 6.4, accuracy: 0.001)
    }
}
