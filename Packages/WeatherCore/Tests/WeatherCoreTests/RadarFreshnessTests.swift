import XCTest
@testable import WeatherCore

final class RadarFreshnessTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_795_880_520) // a whole 6-minute mark

    func testLevelsAndText() {
        XCTAssertEqual(RadarFreshness.level(latest: now.addingTimeInterval(-8 * 60), now: now), .fresh)
        XCTAssertEqual(RadarFreshness.level(latest: now.addingTimeInterval(-22 * 60), now: now), .late)
        XCTAssertEqual(RadarFreshness.level(latest: now.addingTimeInterval(-45 * 60), now: now), .stale)
        XCTAssertEqual(RadarFreshness.text(latest: now.addingTimeInterval(-8 * 60), now: now), "Latest radar scan 8 min ago.")
        XCTAssertEqual(RadarFreshness.text(latest: now.addingTimeInterval(-22 * 60), now: now), "Radar is running late: latest scan 22 min ago.")
        XCTAssertEqual(RadarFreshness.text(latest: now.addingTimeInterval(-70 * 60), now: now),
                       "Radar is behind: latest scan 1 hr 10 min ago, so rain may have moved since.")
    }

    func testRelativeIsFromTheClock() {
        XCTAssertEqual(RadarFreshness.relative(now.addingTimeInterval(-60), now: now), "Now")
        XCTAssertEqual(RadarFreshness.relative(now.addingTimeInterval(-20 * 60), now: now), "20 min ago")
        XCTAssertEqual(RadarFreshness.relative(now.addingTimeInterval(12 * 60), now: now), "in 12 min")
    }

    func testNewestFrameFromTheSpotsReading() async {
        let json = #"{"type":"FeatureCollection","features":[{"properties":{"value":0.0,"time":"2026-11-28T15:54:00Z"}}]}"#
        let provider = ECCCRadarProvider { req in
            (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let latest = await RadarFreshness.latestECCCFrame(at: Coordinate(latitude: 43.51, longitude: -79.88), provider: provider)
        XCTAssertEqual(latest, ISO8601DateFormatter().date(from: "2026-11-28T15:54:00Z"))
    }

    func testLoopEndsAtNewestPublishedFrame() {
        let late = now.addingTimeInterval(-24 * 60)
        let times = RadarFreshness.ecccFrameTimes(latest: late, now: now)
        XCTAssertEqual(times.count, 10)
        XCTAssertEqual(times.last, late)
        XCTAssertEqual(times.first, late.addingTimeInterval(-9 * 6 * 60))
        // Unknown or nonsense newest frame: the old guess, 9+ minutes back on a 6-minute mark.
        let guess = RadarFreshness.ecccFrameTimes(latest: nil, now: now).last!
        XCTAssertEqual(guess, now.addingTimeInterval(-12 * 60))
        XCTAssertEqual(RadarFreshness.ecccFrameTimes(latest: now.addingTimeInterval(3600), now: now).last, guess)
        // Three hours, every second frame, never older than GeoMet keeps.
        let three = RadarFreshness.ecccFrameTimes(latest: late, hours: 3, now: now)
        XCTAssertTrue(three.allSatisfy { now.timeIntervalSince($0) <= 3 * 3600 - 360 })
    }
}
