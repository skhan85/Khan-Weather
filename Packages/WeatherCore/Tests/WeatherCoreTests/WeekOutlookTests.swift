import XCTest
@testable import WeatherCore

final class WeekOutlookTests: XCTestCase {
    let tz = TimeZone(identifier: "America/Toronto")!

    /// Sat 28 Nov 2026, 11 am Toronto.
    var now: Date { ISO8601DateFormatter().date(from: "2026-11-28T16:00:00Z")! }

    func days(_ rows: [(high: Double, low: Double, condition: WeatherCondition, gust: Double?)]) -> [DailyForecast] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = cal.startOfDay(for: now)
        return rows.enumerated().map { i, r in
            var d = DailyForecast(date: cal.date(byAdding: .day, value: i, to: start)!, high: r.high, low: r.low,
                                  condition: r.condition, rainSum: r.condition.isPrecipitation ? 5 : 0, snowfallSum: 0)
            d.windGustsMax = r.gust
            return d
        }
    }

    func testRainDaysPeakAndGusts() {
        let week = days([(9, 3, .overcast, 30), (8, 4, .rain, 40), (6, 0, .partlyCloudy, 51), (5, -1, .partlyCloudy, nil),
                         (7, 3, .overcast, nil), (12, 2, .overcast, nil), (7, 3, .rain, nil)])
        XCTAssertEqual(WeekOutlook.text(week, timeZone: tz, now: now),
                       "Rain tomorrow and Friday, highs peaking at 12° Thursday. Gusts up to 51 km/h Monday.")
    }

    func testDryWeekWithHardFrost() {
        let week = days([(2, -3, .clear, nil), (1, -8, .clear, nil), (3, -2, .partlyCloudy, nil)])
        XCTAssertEqual(WeekOutlook.text(week, timeZone: tz, now: now),
                       "Dry for the next 3 days, highs peaking at 3° Monday. Hard frost tomorrow night, down to -8°.")
    }

    func testManyWetDays() {
        let week = days([(7, 3, .rain, nil), (7, 3, .rain, nil), (7, 3, .rain, nil), (7, 3, .rain, nil), (7, 3, .rain, nil), (7, 3, .rain, nil), (8, 2, .overcast, nil)])
        XCTAssertEqual(WeekOutlook.text(week, timeZone: tz, now: now), "Rain on 6 of the next 7 days, highs peaking at 8° Friday.")
    }
}
