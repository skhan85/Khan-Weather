import XCTest
@testable import WeatherCore

final class AlertProviderTests: XCTestCase {
    /// Shape copied from api.weather.gc.ca/collections/weather-alerts/items (sampled 2026-11-13);
    /// polygons moved to the Milton area for the test.
    static func feature(id: String, code: String, type: String, name: String, colour: String, status: String,
                        expires: String, ring: String) -> String {
        """
        {"type": "Feature", "id": "\(id)",
         "geometry": {"type": "Polygon", "coordinates": [\(ring)]},
         "properties": {"alert_code": "\(code)", "alert_type": "\(type)", "alert_name_en": "\(name)",
           "alert_name_fr": "x", "alert_short_name_en": "Wind", "publication_datetime": "2026-11-12T23:13:10.328Z",
           "expiration_datetime": "\(expires)", "validity_datetime": "2026-11-12T23:11:00.000Z",
           "event_end_datetime": "2026-11-13T06:00:00.000Z",
           "alert_text_en": "Strong winds, with gusts up to 90 km/h, are possible.\\n\\nSecure loose objects.",
           "risk_colour_en": "\(colour)", "confidence_en": null, "impact_en": null,
           "feature_name_en": "Halton Hills - Milton", "province": "ON", "status_en": "\(status)",
           "feature_id": "fea1-2495"}}
        """
    }

    /// Box around Milton, and one well to the east that doesn't include it.
    static let miltonRing = "[[-80.0,43.4],[-79.7,43.4],[-79.7,43.6],[-80.0,43.6],[-80.0,43.4]]"
    static let torontoRing = "[[-79.6,43.6],[-79.2,43.6],[-79.2,43.8],[-79.6,43.8],[-79.6,43.6]]"

    static let sample: Data = {
        let f = [
            feature(id: "111_fea1-1", code: "WDW", type: "warning", name: "wind warning", colour: "yellow",
                    status: "issued", expires: "2026-11-13T08:01:10.328Z", ring: miltonRing),
            // Same alert, second zone: shown once.
            feature(id: "111_fea1-2", code: "WDW", type: "warning", name: "wind warning", colour: "yellow",
                    status: "issued", expires: "2026-11-13T08:01:10.328Z", ring: miltonRing),
            feature(id: "222_fea1-1", code: "SPS", type: "statement", name: "special weather statement",
                    colour: "yellow", status: "continued", expires: "2026-11-13T08:01:10.328Z", ring: miltonRing),
            feature(id: "333_fea1-1", code: "BZW", type: "warning", name: "blizzard warning", colour: "orange",
                    status: "ended", expires: "2026-11-13T08:01:10.328Z", ring: miltonRing),
            feature(id: "444_fea1-1", code: "FGA", type: "advisory", name: "fog advisory", colour: "yellow",
                    status: "issued", expires: "2026-11-12T20:00:00.000Z", ring: miltonRing),
            feature(id: "555_fea1-1", code: "SQW", type: "warning", name: "squall warning", colour: "orange",
                    status: "issued", expires: "2026-11-13T08:01:10.328Z", ring: torontoRing),
        ]
        return #"{"type": "FeatureCollection", "numberMatched": 6, "numberReturned": 6, "features": ["#
            .appending(f.joined(separator: ",")).appending("]}").data(using: .utf8)!
    }()

    let milton = Coordinate(latitude: 43.513, longitude: -79.882)
    let now = ISO8601DateFormatter().date(from: "2026-11-13T01:00:00Z")!

    func testKeepsActiveAlertsCoveringThePoint() throws {
        let alerts = try ECCCAlertProvider.parse(Self.sample, at: milton, now: now)
        XCTAssertEqual(alerts.map(\.title), ["Wind warning", "Special weather statement"],
                       "drops ended, expired, other-area and duplicate-zone alerts; warnings first")
        let wind = try XCTUnwrap(alerts.first)
        XCTAssertEqual(wind.id, "111")
        XCTAssertEqual(wind.kind, .warning)
        XCTAssertEqual(wind.risk, .yellow)
        XCTAssertEqual(wind.area, "Halton Hills - Milton")
        XCTAssertTrue(wind.text.contains("\n\nSecure loose objects."))
        XCTAssertEqual(wind.expiresAt, EnvironmentCanadaProvider.parseDate("2026-11-13T08:01:10.328Z"))
    }

    func testEmptyCollection() throws {
        let data = #"{"type": "FeatureCollection", "numberMatched": 0, "numberReturned": 0, "features": []}"#
        XCTAssertEqual(try ECCCAlertProvider.parse(data.data(using: .utf8)!, at: milton, now: now), [])
    }

    func testPolygonHoleAndMultiPolygon() throws {
        let json = """
        {"type": "MultiPolygon", "coordinates": [
          [[[0,0],[10,0],[10,10],[0,10],[0,0]], [[4,4],[6,4],[6,6],[4,6],[4,4]]],
          [[[20,20],[30,20],[30,30],[20,30],[20,20]]]
        ]}
        """
        let g = try JSONDecoder().decode(ECCCAlertProvider.Geometry.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(g.contains(Coordinate(latitude: 2, longitude: 2)))
        XCTAssertFalse(g.contains(Coordinate(latitude: 5, longitude: 5)), "inside the hole")
        XCTAssertTrue(g.contains(Coordinate(latitude: 25, longitude: 25)))
        XCTAssertFalse(g.contains(Coordinate(latitude: 15, longitude: 15)))
    }

    func testURLUsesSmallBox() {
        let url = ECCCAlertProvider.url(for: milton).absoluteString
        XCTAssertTrue(url.hasPrefix("https://api.weather.gc.ca/collections/weather-alerts/items?"))
        XCTAssertTrue(url.contains("bbox=-79.8920,43.5030,-79.8720,43.5230"))
        XCTAssertTrue(url.contains("lang=en"))
    }
}
