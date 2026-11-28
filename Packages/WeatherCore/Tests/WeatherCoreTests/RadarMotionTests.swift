import XCTest
@testable import WeatherCore

final class RadarMotionTests: XCTestCase {
    func testColoursReadAsTheirDBZ() {
        XCTAssertEqual(RadarMotion.dbz(r: 0x00, g: 0xa3, b: 0xe0, a: 255), 20)
        XCTAssertEqual(RadarMotion.dbz(r: 0xc1, g: 0x00, b: 0x00, a: 255), 50)
        XCTAssertNil(RadarMotion.dbz(r: 0, g: 0, b: 0, a: 0))
        XCTAssertEqual(RadarMotion.rainRate(20), 0.65, accuracy: 0.01)
        XCTAssertEqual(RadarMotion.rainRate(5), 0)
    }

    /// A shower 30 km west of the spot, moving east at 45 km/h, reaches it in about 40 minutes.
    func testShowerUpstreamArrivesOnTime() {
        let w = 512, km = 1.5
        func frame(shiftKm: Double) -> RadarMotion.Grid {
            var d = [Double?](repeating: nil, count: w * w)
            let cx = 256 - 30 / km + shiftKm / km, cy = 256.0
            for y in 0..<w { for x in 0..<w {
                let dx = Double(x) - cx, dy = Double(y) - cy
                if dx * dx + dy * dy < 64 { d[y * w + x] = 35 }
                if (dx - 12) * (dx - 12) + (dy + 9) * (dy + 9) < 20 { d[y * w + x] = 25 }
            } }
            return RadarMotion.Grid(width: w, height: w, dbz: d)
        }
        let old = frame(shiftKm: -15), new = frame(shiftKm: 0)    // 15 km in 20 min
        let v = RadarMotion.motion(old: old, new: new, x: 256, y: 256, minutes: 20, km: km)
        XCTAssertEqual(v.dx * 20 * km, 15, accuracy: 1.6)
        XCTAssertEqual(v.dy, 0, accuracy: 0.05)
        let nc = RadarMotion.nowcast(old: old, new: new, time: Date(timeIntervalSince1970: 0), minutes: 20, x: 256, y: 256, km: km)
        XCTAssertEqual(nc.slots.first?.rain_mmh, 0)
        let wet = nc.slots.filter { $0.rain_mmh > 1 }.map(\.epoch)
        XCTAssertEqual((wet.first ?? 0) / 60, 30, accuracy: 6)    // leading edge 8 px (~12 km) ahead of centre
        XCTAssertNotNil(nc.slots.first { $0.epoch == 40 * 60 && $0.rain_mmh > 3 })
    }

    func testStillRainStaysPut() {
        let w = 512
        var d = [Double?](repeating: nil, count: w * w)
        for y in 230..<280 { for x in 230..<280 { d[y * w + x] = 30 } }
        let g = RadarMotion.Grid(width: w, height: w, dbz: d)
        let nc = RadarMotion.nowcast(old: g, new: g, time: Date(timeIntervalSince1970: 0), minutes: 20, x: 256, y: 256, km: 1.5)
        XCTAssertEqual(nc.slots.count, 19)
        XCTAssertTrue(nc.slots.allSatisfy { $0.rain_mmh > 2 })
    }

    func testFramePairPicksTwentyMinutesBack() {
        let frames = stride(from: 0.0, through: 7200, by: 600).map { RadarMotion.Index.Frame(time: $0, path: "/p\(Int($0))") }
        let p = RadarMotion.framePair(frames)
        XCTAssertEqual(p?.new.time, 7200)
        XCTAssertEqual(p?.old.time, 6000)
    }

    func testTilesKeepTheSpotNearTheMiddle() {
        let t = RadarMotion.tiles(for: Coordinate(latitude: 45.52, longitude: -122.99))
        XCTAssertTrue((128.0...384.0).contains(t.x))
        XCTAssertTrue((128.0...384.0).contains(t.y))
    }
}
