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

    func testParsesGeoMetTimeExtent() {
        let xml = """
        <Layer><Name>RADAR_1KM_RRAI</Name><Dimension name="time" units="ISO8601" default="2026-11-28T15:48:00Z" nearestValue="0">2026-11-28T12:54:00Z/2026-11-28T15:48:00Z/PT6M</Dimension></Layer>
        """
        XCTAssertEqual(RadarFreshness.parseLatest(xml), ISO8601DateFormatter().date(from: "2026-11-28T15:48:00Z"))
        let defaultOnly = #"<Dimension name="time" units="ISO8601" default="2026-11-28T15:42:00Z"></Dimension>"#
        XCTAssertEqual(RadarFreshness.parseLatest(defaultOnly), ISO8601DateFormatter().date(from: "2026-11-28T15:42:00Z"))
        XCTAssertNil(RadarFreshness.parseLatest("<html>error</html>"))
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
