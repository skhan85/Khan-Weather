import XCTest
@testable import WeatherCore

final class BlendRegionTests: XCTestCase {
    /// The Swift table must say exactly what blend-regions.json says (the file other ports read).
    func testSwiftTableMatchesJSON() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("blend-regions.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let json = try XCTUnwrap(root["regions"] as? [[String: Any]]) + [try XCTUnwrap(root["global"] as? [String: Any])]
        let swift = BlendRegion.regions + [BlendRegion.fallback]
        XCTAssertEqual(json.count, swift.count)
        for (j, s) in zip(json, swift) {
            XCTAssertEqual(j["id"] as? String, s.id)
            XCTAssertEqual(j["useBlend"] as? Bool, s.useBlend, s.id)
            XCTAssertEqual((j["models"] as? [String])?.compactMap { name in s.models.first { "\($0)" == name } }.count,
                           s.models.count, s.id)
            let boxes = (j["boxes"] as? [[Double]]) ?? []
            XCTAssertEqual(boxes, s.boxes.map { [$0.latMin, $0.latMax, $0.lonMin, $0.lonMax] }, s.id)
            let bands = (j["shortRange"] as? [[String: Double]]) ?? []
            XCTAssertEqual(bands.count, s.shortRange.count, s.id)
            for (jd, sd) in zip(bands, s.shortRange) {
                XCTAssertEqual(jd.count, sd.count, s.id)
                for (model, w) in sd { XCTAssertEqual(jd["\(model)"] ?? -1, w, accuracy: 1e-9, "\(s.id) short \(model)") }
                for m in sd.keys { XCTAssertTrue(s.models.contains(m), "\(s.id) short-range weights \(m) but doesn't ask for it") }
            }
            let days = try XCTUnwrap(j["byDay"] as? [[String: Double]])
            XCTAssertEqual(days.count, s.byDay.count, s.id)
            for (jd, sd) in zip(days, s.byDay) {
                XCTAssertEqual(jd.count, sd.count, s.id)
                for (model, w) in sd {
                    XCTAssertEqual(jd["\(model)"] ?? -1, w, accuracy: 1e-9, "\(s.id) \(model)")
                }
            }
        }
    }

    func testEveryRegionsWeightsAddUpAndAreAskedFor() {
        for r in BlendRegion.regions + [BlendRegion.fallback] {
            XCTAssertEqual(r.byDay.count, 6, r.id)
            for day in r.byDay {
                XCTAssertEqual(day.values.reduce(0, +), 1, accuracy: 0.01, r.id)
                for m in day.keys { XCTAssertTrue(r.models.contains(m), "\(r.id) weights \(m) but doesn't ask for it") }
            }
        }
    }

    func testRegionLookup() {
        XCTAssertEqual(BlendRegion.at(Coordinate(latitude: 43.52, longitude: -79.88)).id, "na_east")   // Milton
        XCTAssertEqual(BlendRegion.at(Coordinate(latitude: 49.28, longitude: -123.12)).id, "na_west")  // Vancouver
        XCTAssertEqual(BlendRegion.at(Coordinate(latitude: 51.5, longitude: -0.12)).id, "europe")      // London
        XCTAssertEqual(BlendRegion.at(Coordinate(latitude: 24.86, longitude: 67.0)).id, "sw_asia")     // Karachi
        XCTAssertEqual(BlendRegion.at(Coordinate(latitude: 35.68, longitude: 139.7)).id, "east_asia")  // Tokyo
        XCTAssertEqual(BlendRegion.at(Coordinate(latitude: -33.87, longitude: 151.2)).id, "oceania")   // Sydney
        XCTAssertEqual(BlendRegion.at(Coordinate(latitude: -23.55, longitude: -46.63)).id, "global")   // São Paulo
        XCTAssertEqual(BlendRegion.home.id, "na_east")
        XCTAssertTrue(BlendRegion.at(Coordinate(latitude: 43.52, longitude: -79.88)).models.contains(.uk))
        let europe = BlendRegion.at(Coordinate(latitude: 51.5, longitude: -0.12))
        XCTAssertFalse(europe.models.contains(.us))
        XCTAssertTrue(europe.models.contains(.norway))
        XCTAssertTrue(BlendRegion.at(Coordinate(latitude: 35.68, longitude: 139.7)).models.contains(.japan))
    }

    func testBlendUsesTheSpotsWeights() {
        let london = BlendRegion.at(Coordinate(latitude: 51.5, longitude: -0.12))
        let values = Dictionary(uniqueKeysWithValues: london.models.enumerated().map { ($1, Double($0)) })
        let expected: Double = {
            let w = london.byDay[2].filter { values[$0.key] != nil }
            return w.reduce(0) { $0 + values[$1.key]! * $1.value } / w.values.reduce(0, +)
        }()
        XCTAssertEqual(ModelBlend.blend(values, leadHours: 60, region: london)!, expected, accuracy: 1e-9)
    }

    /// The short-range bands run into day 0 at hour 12 without a jump, and day 0 is unchanged after.
    func testShortRangeBandsJoinDayZero() {
        var r = BlendRegion.fallback
        r.shortRange = [[.germany: 1], [.germany: 0.5, .europe: 0.5], [.europe: 1]]
        XCTAssertEqual(ModelBlend.tablePrior(.germany, leadHours: 0, region: r), 1)
        XCTAssertEqual(ModelBlend.tablePrior(.germany, leadHours: 2.5, region: r), 0.75, accuracy: 1e-9)
        XCTAssertEqual(ModelBlend.tablePrior(.europe, leadHours: 8.5, region: r), 1)
        let day0 = r.byDay[0][.europe] ?? 0
        XCTAssertEqual(ModelBlend.tablePrior(.europe, leadHours: 12, region: r), day0, accuracy: 1e-9)
        XCTAssertEqual(ModelBlend.tablePrior(.europe, leadHours: 10.25, region: r), (1 + day0) / 2, accuracy: 1e-9)
        var plain = r
        plain.shortRange = []
        XCTAssertEqual(ModelBlend.tablePrior(.europe, leadHours: 3, region: plain), day0, accuracy: 1e-9)
    }
}
