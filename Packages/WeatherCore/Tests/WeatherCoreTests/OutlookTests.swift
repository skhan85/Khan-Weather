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
}
