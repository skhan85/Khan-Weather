import XCTest
@testable import WeatherCore

final class AccuracyTests: XCTestCase {
    func testScoresRankModelsByAverageMiss() {
        var log = AccuracyLog()
        log.record(.init(day: "2026-11-13", highs: ["gem_seamless": 5, "gfs_seamless": 8], lows: ["gem_seamless": 0, "gfs_seamless": 3]))
        log.record(.init(day: "2026-11-14", highs: ["gem_seamless": 6, "gfs_seamless": 6], lows: ["gem_seamless": 1, "gfs_seamless": 1]))
        log.record(.init(day: "2026-11-14", highs: ["gem_seamless": 99], lows: [:]))   // later copy ignored
        log.record(.init(day: "2026-11-13", high: 6, low: 1, station: "Georgetown"))
        XCTAssertEqual(log.unscoredDays(before: "2026-11-15"), ["2026-11-14"])
        let scores = log.scores()
        XCTAssertEqual(scores.map(\.model), [.canada, .us])
        XCTAssertEqual(scores[0].highError, 1)
        XCTAssertEqual(scores[1].lowError, 2)
        XCTAssertEqual(scores[0].days, 1)
    }

    func testDayString() {
        let date = Date(timeIntervalSince1970: 1_794_736_800)   // 2026-11-15 10:00 UTC, 5 AM in Toronto
        let toronto = TimeZone(identifier: "America/Toronto")!
        XCTAssertEqual(AccuracyLog.dayString(date, timeZone: toronto), "2026-11-15")
        XCTAssertEqual(AccuracyLog.dayString(date, timeZone: toronto, offsetDays: 1), "2026-11-16")
    }

    func testParsesNearestClimateStation() throws {
        let json = """
        {"features": [
          {"geometry": {"coordinates": [-79.92, 43.65]},
           "properties": {"STATION_NAME": "GEORGETOWN WWTP", "LOCAL_DATE": "2026-11-13 00:00:00",
                          "MAX_TEMPERATURE": 6.5, "MIN_TEMPERATURE": 0.5}},
          {"geometry": {"coordinates": [-79.63, 43.68]},
           "properties": {"STATION_NAME": "TORONTO INTL A", "LOCAL_DATE": "2026-11-13 00:00:00",
                          "MAX_TEMPERATURE": 7.0, "MIN_TEMPERATURE": 1.0}},
          {"geometry": {"coordinates": [-79.88, 43.52]},
           "properties": {"STATION_NAME": "NO DATA", "LOCAL_DATE": "2026-11-13 00:00:00",
                          "MAX_TEMPERATURE": null, "MIN_TEMPERATURE": null}}
        ]}
        """
        let seen = try XCTUnwrap(ClimateDailyProvider.parse(Data(json.utf8), day: "2026-11-13",
                                                            near: Coordinate(latitude: 43.52, longitude: -79.88)))
        XCTAssertEqual(seen.station, "Georgetown Wwtp")
        XCTAssertEqual(seen.high, 6.5)
    }
}
