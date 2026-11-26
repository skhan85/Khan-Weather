import XCTest
@testable import WeatherCore

final class OutlookTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/Toronto")!

    /// Local time on 2026-11-20 in Toronto (UTC-5), plus `addingHours`.
    private func local(_ hour: Int, addingHours extra: Int = 0) -> Date {
        // 2026-11-20 00:00 EST = 05:00 UTC.
        Date(timeIntervalSince1970: 1_795_150_800).addingTimeInterval(Double(hour + extra) * 3600)
    }

    private func hourText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "h a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: date)
    }

    private func forecast(startHour: Int, temps: [Double], high: Double, low: Double,
                          rainAt: Int? = nil) -> Forecast {
        let now = local(startHour)
        let hourly = temps.enumerated().map { i, t in
            HourlyForecast(time: local(startHour, addingHours: i), temperature: t,
                           precipitationProbability: i == rainAt ? 80 : 0,
                           precipitation: i == rainAt ? 1 : 0,
                           condition: i == rainAt ? .rain : .clear)
        }
        let current = CurrentConditions(time: now, temperature: temps[0], feelsLike: temps[0],
                                        feelsLikeKind: .apparent, condition: .clear, isDay: false)
        let days = [DailyForecast(date: local(0), high: high, low: low, condition: .clear),
                    DailyForecast(date: local(24), high: 12, low: 3, condition: .clear)]
        return Forecast(location: .fallback, timeZoneIdentifier: tz.identifier, current: current,
                        hourly: hourly, daily: days, source: "test", fetchedAt: now)
    }

    // 4 am, 9°: the screenshot case. Six hours ahead only reached 11° at 10 am, while the
    // hourly and today's high go on to 15° at 1 pm.
    private let earlyMorning: [Double] = [9, 8.8, 8.6, 8.7, 9, 9.8, 11, 12.4, 13.6, 14.8, 15, 15, 14.2,
                                          13, 11.5, 10.5, 10, 9.6, 9.2, 9]

    func testEarlyMorningWarmingReachesTodaysHigh() {
        let f = forecast(startHour: 4, temps: earlyMorning, high: 15, low: 7)
        XCTAssertEqual(Outlook.text(f, at: local(4), hourText: hourText), "Warming to a high of 15° by 1 pm.")
    }

    func testWarmingNotCalledTheHighWhenTheDailyHighDiffers() {
        let f = forecast(startHour: 4, temps: earlyMorning, high: 17, low: 7)
        XCTAssertEqual(Outlook.text(f, at: local(4), hourText: hourText), "Warming to 15° by 1 pm.")
    }

    // 9 pm, 5°: the screenshot case. Tomorrow warms to 16° by 2 pm, but at night the sentence
    // should give tonight's low instead, the same number as the high/low chip.
    private let lateEvening: [Double] = [5, 4.8, 4.6, 4.4, 4.2, 4, 3.8, 3.6, 3.4, 3.3, 3.5, 4.5, 7, 10, 12.5,
                                         14.5, 15.2, 16, 15.5]

    func testLateEveningGivesTonightsLowNotTomorrowsHigh() {
        let f = forecast(startHour: 21, temps: lateEvening, high: 14, low: 7)
        XCTAssertEqual(f.displayDay(at: local(21))?.low, 3.3)
        XCTAssertEqual(Outlook.text(f, at: local(21), hourText: hourText), "Cooling to a low of 3° by 5 am.")
    }

    func testMorningGoesBackToTheWarmUp() {
        // At 5 am the night is over: back to the day's warm-up.
        let f = forecast(startHour: 5, temps: Array(lateEvening.dropFirst(8)), high: 16, low: 7)
        XCTAssertEqual(Outlook.text(f, at: local(5), hourText: hourText), "Warming to a high of 16° by 2 pm.")
    }

    func testNightWithNoFurtherDropFallsBack() {
        let temps: [Double] = [3, 3.2, 3.4, 3.6, 3.8, 4, 4.2, 4.4, 4.6, 5, 6, 8, 10, 12, 14, 15, 16, 16, 15]
        let f = forecast(startHour: 21, temps: temps, high: 14, low: 7)
        XCTAssertEqual(Outlook.text(f, at: local(21), hourText: hourText), "Warming to 16° by 1 pm.")
    }

    func testEveningCoolingReachesTonightsLow() {
        let temps: [Double] = [11, 10, 9, 8, 7, 6.4, 5.6, 5, 4.6, 4.3, 4.1, 3.9, 4, 4.5, 5.5, 7, 9, 10, 11]
        let f = forecast(startHour: 18, temps: temps, high: 15, low: 7)
        XCTAssertEqual(f.displayDay(at: local(18))?.low, 3.9, "tonight's low on the Now card")
        XCTAssertEqual(Outlook.text(f, at: local(18), hourText: hourText), "Cooling to a low of 4° by 3 am.")
    }

    func testWarmUpStopsWhenItTurnsBack() {
        // Up 3° by 7 am, back down, then a later rise the sentence shouldn't jump to.
        let temps: [Double] = [5, 6, 7, 8, 7, 6, 5.5, 5, 6, 8, 10, 12, 13]
        let f = forecast(startHour: 4, temps: temps, high: 13, low: 5)
        XCTAssertEqual(Outlook.text(f, at: local(4), hourText: hourText), "Warming to 8° by 7 am.")
    }

    func testRainComesFirst() {
        let f = forecast(startHour: 4, temps: earlyMorning, high: 15, low: 7, rainAt: 3)
        XCTAssertEqual(Outlook.text(f, at: local(4), hourText: hourText), "Rain likely around 7 am.")
    }

    func testSteady() {
        let temps: [Double] = [9, 9.2, 9.4, 9.1, 8.9, 9.3, 9, 9.4, 9.2]
        let f = forecast(startHour: 13, temps: temps, high: 9.4, low: 8.9)
        XCTAssertEqual(Outlook.text(f, at: local(13), hourText: hourText),
                       "Steady around 9° for the next few hours.")
    }

    func testQuotedNumberMatchesTheHourlyCurve() {
        let f = forecast(startHour: 4, temps: earlyMorning, high: 15, low: 7)
        let curve = f.hoursStartingNow(from: local(4), count: 24)
        let onePM = curve.first { $0.time == local(13) }
        XCTAssertEqual(onePM.map { WeatherFormat.temperature($0.temperature) }, "15°")
    }

    func testOvernightLowMatchesHourlyCurveWhenAllowanceDiffers() {
        // 6:15 pm, 3°. Hourly curve reaches 1° at 11 pm (and 0.6° -> 1° at 1 am), while
        // extremesIncludePeak subtracts 0.5° from displayDay.low (0.1° -> 0°).
        // Outlook must quote 1° at 11 pm to match the Next 24 hours curve, never "0° by 11 pm".
        let temps: [Double] = [3.0, 2.5, 2.0, 1.8, 1.5, 1.1, 0.8, 0.6, 0.7, 0.9, 1.2, 1.6, 2.5, 4.0, 6.0]
        var f = forecast(startHour: 18, temps: temps, high: 7, low: 1)
        f.extremesIncludePeak = true
        let now = local(18).addingTimeInterval(15 * 60)
        f.current.time = now
        XCTAssertEqual(f.displayDay(at: now)?.low ?? 99, 0.1, accuracy: 0.01)
        let elevenPM = f.hoursStartingNow(from: now, count: 24).first { $0.time == local(23) }
        XCTAssertEqual(elevenPM.map { WeatherFormat.temperature($0.temperature) }, "1°")
        XCTAssertEqual(Outlook.text(f, at: now, hourText: hourText), "Cooling to 1° by 11 pm.")
    }

    func testWarmingNightWithAllowanceDoesNotSayCooling() {
        // 9:15 pm, 2.9° (3°), warming all night; lowAllowance on now must not trigger "Cooling".
        let temps: [Double] = [2.9, 3.2, 3.5, 4.0, 4.5, 5.0, 6.0, 8.0, 10.0, 12.0, 14.0, 15.0, 16.0]
        var f = forecast(startHour: 21, temps: temps, high: 14, low: 3)
        f.extremesIncludePeak = true
        let now = local(21).addingTimeInterval(15 * 60)
        f.current.time = now
        XCTAssertEqual(Outlook.text(f, at: now, hourText: hourText), "Warming to 16° by 9 am.")
    }
}

final class CompareRowMatchesAppTests: XCTestCase {
    func testKhanWeatherRowShowsTheAppsHighAndLow() {
        let tz = TimeZone(identifier: "America/Toronto")!
        let today = Date(timeIntervalSince1970: 1_795_150_800)   // 2026-11-20 00:00 Toronto
        let tomorrow = today.addingTimeInterval(86_400)
        let rows = [
            ModelDay(model: .blend, date: today, high: 16.2, low: 4.1, condition: .clear),
            ModelDay(model: .canada, date: today, high: 16, low: 4, condition: .clear),
            ModelDay(model: .blend, date: tomorrow, high: 12.4, low: 3, condition: .clear),
            ModelDay(model: .blend, date: tomorrow.addingTimeInterval(86_400), high: 9, low: 1, condition: .clear),
        ]
        let appDays = [DailyForecast(date: today, high: 15.1, low: 7.2, condition: .clear),
                       DailyForecast(date: tomorrow, high: 11.8, low: 3.4, condition: .clear)]
        let out = ModelComparisonProvider.showingApp(rows, appDays: appDays, used: .blend, timeZone: tz)
        XCTAssertEqual(out[0].high, 15.1)
        XCTAssertEqual(out[0].low, 7.2)
        XCTAssertEqual(out[1].high, 16, "other models keep their own numbers")
        XCTAssertEqual(out[2].high, 11.8)
        XCTAssertEqual(out[2].low, 3.4)
        XCTAssertEqual(out[3].high, 9, "a day the app doesn't have keeps the blend")
    }

    func testCompareUsesCalendarDayLowInsteadOfTonightLow() {
        let tz = TimeZone(identifier: "America/Toronto")!
        let today = Date(timeIntervalSince1970: 1_795_150_800)   // 2026-11-20 00:00 Toronto
        let tomorrow = today.addingTimeInterval(86_400)
        // Morning was -5°, tonight is 0°. Calendar daily[0] keeps -5°; displayDaily()[0] uses 0°.
        let hours = (0..<36).map { h in
            HourlyForecast(time: today.addingTimeInterval(Double(h) * 3600),
                           temperature: h == 6 ? -5.0 : (h >= 24 ? 0.0 : 4.0),
                           condition: .clear)
        }
        let forecast = Forecast(
            location: .fallback, timeZoneIdentifier: "America/Toronto",
            current: CurrentConditions(time: today.addingTimeInterval(19 * 3600), temperature: 2.0,
                                       feelsLike: 2.0, feelsLikeKind: .apparent, condition: .clear, isDay: false),
            hourly: hours,
            daily: [DailyForecast(date: today, high: 4.0, low: -5.0, condition: .clear),
                    DailyForecast(date: tomorrow, high: 5.0, low: 0.0, condition: .clear)],
            source: "test", fetchedAt: today
        )
        let rows = [ModelDay(model: .blend, date: today, high: 4.0, low: -4.0, condition: .clear)]
        let compared = ModelComparisonProvider.showingApp(rows, appDays: forecast.daily, used: .blend, timeZone: tz)
        XCTAssertEqual(compared[0].low, -5.0)
        XCTAssertEqual(forecast.displayDaily(at: today.addingTimeInterval(19 * 3600))[0].low, 0.0)
    }
}

final class TodaysHighOnTheCurveTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/Toronto")!
    private let midnight = Date(timeIntervalSince1970: 1_795_150_800)   // 2026-11-20 00:00 Toronto

    private func hourText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "h a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: date)
    }

    /// 6:40 am, 8°. The day peaks at 15.6° at 1 pm between two 15.4° hours, so the daily high is
    /// 16°. The rounding-blip rule used to flatten that hour to 15°, and the summary said
    /// "Warming to 15° by 12 pm" under a 16° high.
    private func forecast() -> Forecast {
        let temps: [Double] = [7.5, 7.3, 7.1, 7, 7.2, 7.6, 7.9, 8, 8.1, 9, 11, 13, 15.4, 15.6, 15.4, 14.6,
                               13, 11.5, 10, 8.5, 7, 5.5, 4.5, 3.8, 3.6, 3.4, 3.6, 4]
        let hourly = temps.enumerated().map { i, t in
            HourlyForecast(time: midnight.addingTimeInterval(Double(i) * 3600), temperature: t, condition: .clear)
        }
        let now = midnight.addingTimeInterval(6 * 3600 + 40 * 60)
        let current = CurrentConditions(time: now, temperature: 8, feelsLike: 6, feelsLikeKind: .apparent,
                                        condition: .clear, isDay: false)
        let days = [DailyForecast(date: midnight, high: 15.6, low: 7, condition: .clear),
                    DailyForecast(date: midnight.addingTimeInterval(86_400), high: 12, low: 3.1, condition: .clear)]
        return Forecast(location: .fallback, timeZoneIdentifier: tz.identifier, current: current,
                        hourly: hourly, daily: days, source: "test", fetchedAt: now)
    }

    func testCurveKeepsTheDaysHigh() {
        let f = forecast()
        let now = midnight.addingTimeInterval(6 * 3600 + 40 * 60)
        let curve = f.hoursStartingNow(from: now, count: 24)
        let shownMax = curve.filter { $0.time < midnight.addingTimeInterval(86_400) }
            .map { Int($0.temperature.rounded()) }.max()
        XCTAssertEqual(shownMax, 16)
        XCTAssertEqual(Outlook.text(f, at: now, hourText: hourText), "Warming to a high of 16° by 1 pm.")
    }

    func testCurveKeepsTonightsLow() {
        let f = forecast()
        let now = midnight.addingTimeInterval(6 * 3600 + 40 * 60)
        let curve = f.hoursStartingNow(from: now, count: 24)
        // 3.6, 3.4, 3.6 would read 4°, 3°, 4°, a blip, but 3.4 is tonight's low, so it stays.
        XCTAssertEqual(curve.map(\.temperature).min(), 3.4)
    }

    func testHomeStationsOnByDefaultForAppAndWidget() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HomeStations-\(UUID())"))
        XCTAssertTrue(ObservationSource.usesHyperlocal(defaults))
        defaults.set(false, forKey: ObservationSource.hyperlocalKey)
        XCTAssertFalse(ObservationSource.usesHyperlocal(defaults))
    }
}
