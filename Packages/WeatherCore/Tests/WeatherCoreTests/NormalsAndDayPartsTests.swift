import XCTest
@testable import WeatherCore

final class NormalsAndDayPartsTests: XCTestCase {
    let toronto = TimeZone(identifier: "America/Toronto")!

    func testDayIndex() {
        XCTAssertEqual(ClimateNormals.dayIndex(month: 1, day: 1), 0)
        XCTAssertEqual(ClimateNormals.dayIndex(month: 2, day: 29), ClimateNormals.dayIndex(month: 2, day: 28))
        XCTAssertEqual(ClimateNormals.dayIndex(month: 12, day: 31), 364)
    }

    func testComputeAveragesAndSmooths() throws {
        // Two years where every day is 10/0, except one hot 20 November (30/10) in the second year.
        var dates: [String] = [], highs: [Double?] = [], lows: [Double?] = []
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = c; f.timeZone = c.timeZone; f.dateFormat = "yyyy-MM-dd"
        var d = c.date(from: DateComponents(year: 2019, month: 1, day: 1))!
        let end = c.date(from: DateComponents(year: 2020, month: 12, day: 31))!
        while d <= end {
            let s = f.string(from: d)
            dates.append(s)
            let hot = s == "2020-11-20"
            highs.append(hot ? 30 : 10)
            lows.append(hot ? 10 : 0)
            d = c.date(byAdding: .day, value: 1, to: d)!
        }
        let n = try XCTUnwrap(ClimateNormals.compute(location: Coordinate(latitude: 43.5, longitude: -79.9),
                                                     dates: dates, highs: highs, lows: lows))
        XCTAssertEqual(n.highs.count, 365)
        XCTAssertEqual(n.highs[0], 10, accuracy: 0.001)
        // The hot day is spread over 15 days: 20 extra degrees / (15 days × 2 years).
        let nov20 = ClimateNormals.dayIndex(month: 11, day: 20)
        XCTAssertEqual(n.highs[nov20], 10 + 20.0 / 30, accuracy: 0.01)
        XCTAssertEqual(n.highs[nov20 + 7], 10 + 20.0 / 30, accuracy: 0.01)
        XCTAssertEqual(n.highs[nov20 + 8], 10, accuracy: 0.001)
        let date = c.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        XCTAssertEqual(try XCTUnwrap(n.normal(for: date, timeZone: toronto)).high, n.highs[nov20], accuracy: 0.001)
    }

    func testParseArchiveResponse() throws {
        let days = (1...365).map { i -> String in
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
            let d = c.date(byAdding: .day, value: i - 1, to: c.date(from: DateComponents(year: 2019, month: 1, day: 1))!)!
            let f = DateFormatter(); f.calendar = c; f.timeZone = c.timeZone; f.dateFormat = "yyyy-MM-dd"
            return "\"\(f.string(from: d))\""
        }
        let json = """
        {"daily": {"time": [\(days.joined(separator: ","))],
                   "temperature_2m_max": [\(Array(repeating: "5.0", count: 365).joined(separator: ","))],
                   "temperature_2m_min": [\(Array(repeating: "null", count: 364).joined(separator: ",")),-1.0]}}
        """.data(using: .utf8)!
        // Every low but one is missing, so most days have no low: no normals.
        XCTAssertThrowsError(try ClimateNormalsProvider.parse(json, location: Coordinate(latitude: 0, longitude: 0)))
    }

    func testComparisonText() {
        XCTAssertEqual(NormalComparison.text(high: 16, normalHigh: 7.4, unit: .celsius),
                       "9° warmer than usual · normal high 7°")
        XCTAssertEqual(NormalComparison.text(high: 2, normalHigh: 7, unit: .celsius),
                       "5° colder than usual · normal high 7°")
        XCTAssertEqual(NormalComparison.text(high: 8.5, normalHigh: 7, unit: .celsius),
                       "About usual for the date · normal high 7°")
        XCTAssertEqual(NormalComparison.trend(high: 8.9, normalHigh: 7), 0)
        XCTAssertEqual(NormalComparison.trend(high: 9, normalHigh: 7), 1)
        XCTAssertEqual(NormalComparison.trend(high: 5, normalHigh: 7), -1)
    }

    func testCovers() {
        let n = ClimateNormals(location: Coordinate(latitude: 43.5, longitude: -79.9), highs: [], lows: [])
        XCTAssertTrue(n.covers(Coordinate(latitude: 43.52, longitude: -79.88)))
        XCTAssertFalse(n.covers(Coordinate(latitude: 43.7, longitude: -79.4)))
    }

    /// Midnight, 20 Nov 2026, Toronto.
    var midnight: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = toronto
        return c.date(from: DateComponents(year: 2026, month: 11, day: 20))!
    }

    func testDayPartsFromNow() {
        // Peak 16 at 2 PM, coldest 2 at 4 AM tomorrow, rain likely 7–9 PM.
        let temps: (Int) -> Double = { h in
            if h == 14 { return 16 }
            if h == 28 { return 2 }
            switch h % 24 {
            case 6..<12: return 7
            case 12..<18: return 12
            case 18..<24: return 6
            default: return 4
            }
        }
        let hours = (0..<48).map { h -> HourlyForecast in
            var hour = HourlyForecast(time: midnight.addingTimeInterval(Double(h) * 3600), temperature: temps(h),
                                      feelsLike: temps(h) - 2,
                                      precipitationProbability: (19...21).contains(h) ? 70 : 5,
                                      condition: (19...21).contains(h) ? .rain : .clear,
                                      isDay: (7...16).contains(h % 24))
            hour.rain = (19...21).contains(h) ? 1 : 0
            return hour
        }
        let now = midnight.addingTimeInterval(8 * 3600 + 20 * 60)
        let current = CurrentConditions(time: now, temperature: 5, feelsLike: 3, feelsLikeKind: .apparent,
                                        condition: .clear, isDay: true)
        let f = Forecast(location: Coordinate(latitude: 43.5, longitude: -79.9), timeZoneIdentifier: "America/Toronto",
                         current: current, hourly: hours,
                         daily: [DailyForecast(date: midnight, high: 16, low: 2, condition: .clear)],
                         source: "test", fetchedAt: now)
        let parts = f.dayParts(at: now)
        XCTAssertEqual(parts.map(\.kind), [.morning, .afternoon, .evening, .overnight])
        XCTAssertEqual(parts[1].temperature, 16)
        XCTAssertEqual(parts[1].feelsLike, 14)
        XCTAssertEqual(parts[2].condition, .rain)
        XCTAssertEqual(parts[2].precipitationProbability, 70)
        XCTAssertEqual(parts[3].temperature, 2)
        XCTAssertFalse(parts[3].isDay)
        XCTAssertEqual(parts[0].temperature, 7)
        XCTAssertEqual(parts[0].condition, .clear)
    }
}
