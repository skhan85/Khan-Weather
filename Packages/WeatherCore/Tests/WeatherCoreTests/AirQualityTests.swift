import XCTest
@testable import WeatherCore

final class AirQualityTests: XCTestCase {
    func testParsesCurrentAndTodayPeak() throws {
        let json = """
        {"latitude": 43.5, "longitude": -79.9,
         "current": {"time": 1763130000, "interval": 3600, "us_aqi": 42, "pm2_5": 8.4, "pm10": 12.1,
                     "ozone": 55, "nitrogen_dioxide": 9.5, "alder_pollen": null, "birch_pollen": null,
                     "grass_pollen": null, "mugwort_pollen": null, "olive_pollen": null, "ragweed_pollen": null},
         "hourly": {"time": [1763121600, 1763125200, 1763128800, 1763132400, 1763136000],
                    "us_aqi": [70, 50, 42, 61, null]}}
        """.data(using: .utf8)!
        let aq = try AirQualityProvider.parse(json)
        XCTAssertEqual(aq.usAQI, 42)
        XCTAssertEqual(aq.category, .good)
        XCTAssertEqual(aq.pm25, 8.4)
        // Earlier hours (70) don't count; the rest of today peaks at 61.
        XCTAssertEqual(aq.todayMaxAQI, 61)
        XCTAssertFalse(aq.hasPollenData)
        XCTAssertTrue(aq.pollen.isEmpty)
    }

    func testPollenInEurope() throws {
        let json = """
        {"current": {"time": 1763130000, "us_aqi": 30, "alder_pollen": 0, "birch_pollen": 120.5,
                     "grass_pollen": 25, "mugwort_pollen": 0.2, "olive_pollen": 0, "ragweed_pollen": 0}}
        """.data(using: .utf8)!
        let aq = try AirQualityProvider.parse(json)
        XCTAssertTrue(aq.hasPollenData)
        XCTAssertEqual(aq.pollen.map(\.kind), [.birch, .grass])
        XCTAssertEqual(aq.pollen[0].level, .high)
        XCTAssertEqual(aq.pollen[1].level, .high)
        XCTAssertEqual(Pollen(kind: .grass, grains: 3).level, .low)
        XCTAssertEqual(Pollen(kind: .ragweed, grains: 12).level, .moderate)
    }

    func testCategories() {
        XCTAssertEqual(AQICategory(aqi: 50), .good)
        XCTAssertEqual(AQICategory(aqi: 51), .moderate)
        XCTAssertEqual(AQICategory(aqi: 151), .unhealthy)
        XCTAssertEqual(AQICategory(aqi: 420), .hazardous)
    }

    func testURLAsksForPollen() {
        let url = AirQualityProvider().url(for: Coordinate(latitude: 43.513, longitude: -79.882)).absoluteString
        XCTAssertTrue(url.contains("us_aqi"))
        XCTAssertTrue(url.contains("birch_pollen"))
    }
}

final class RainHeadsUpTests: XCTestCase {
    func testOnlyStartingSoonAndNotTwice() {
        let now = Date(timeIntervalSince1970: 1_763_130_000)
        let soon = Nowcast(kind: .rain, change: .starting(minutes: 25))
        XCTAssertEqual(RainHeadsUp.shouldNotify(soon, lastNotified: nil, now: now), soon)
        XCTAssertNil(RainHeadsUp.shouldNotify(soon, lastNotified: now.addingTimeInterval(-3600), now: now))
        XCTAssertEqual(RainHeadsUp.shouldNotify(soon, lastNotified: now.addingTimeInterval(-4 * 3600), now: now), soon)
        XCTAssertNil(RainHeadsUp.shouldNotify(Nowcast(kind: .rain, change: .starting(minutes: 90)), lastNotified: nil, now: now))
        XCTAssertNil(RainHeadsUp.shouldNotify(Nowcast(kind: .snow, change: .continuing), lastNotified: nil, now: now))
        XCTAssertNil(RainHeadsUp.shouldNotify(nil, lastNotified: nil, now: now))
    }

    func testBodyNamesTheTime() {
        let now = Date(timeIntervalSince1970: 1_763_130_000)
        let text = RainHeadsUp.body(Nowcast(kind: .snow, change: .starting(minutes: 20)), at: now,
                                    timeZone: TimeZone(identifier: "America/Toronto")!)
        XCTAssertTrue(text.hasPrefix("Snow starting in about 20 min, around "), text)
    }
}
