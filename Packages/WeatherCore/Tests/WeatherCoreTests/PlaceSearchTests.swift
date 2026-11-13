import XCTest
@testable import WeatherCore

final class PlaceSearchTests: XCTestCase {
    static let sample = """
    {"results": [
      {"id": 6077243, "name": "Montreal", "latitude": 45.50884, "longitude": -73.58781, "elevation": 216.0,
       "feature_code": "PPLA2", "country_code": "CA", "timezone": "America/Toronto", "population": 1600000,
       "country": "Canada", "admin1": "Quebec"},
      {"id": 2643743, "name": "London", "latitude": 51.50853, "longitude": -0.12574, "country": "United Kingdom",
       "admin1": "England"},
      {"id": 1, "name": "Singapore", "latitude": 1.28967, "longitude": 103.85007, "country": "Singapore"}
    ], "generationtime_ms": 0.9}
    """.data(using: .utf8)!

    func testParsesResults() throws {
        let places = try PlaceSearch.parse(Self.sample)
        XCTAssertEqual(places.map(\.name), ["Montreal", "London", "Singapore"])
        XCTAssertEqual(places[0].detail, "Quebec, Canada")
        XCTAssertEqual(places[0].coordinate.latitude, 45.50884)
        XCTAssertNil(places[2].detail, "don't repeat the name as its own country")
    }

    func testNoResultsKeyMeansEmpty() throws {
        XCTAssertEqual(try PlaceSearch.parse(#"{"generationtime_ms": 0.3}"#.data(using: .utf8)!), [])
    }

    func testURLAndShortQuery() async throws {
        let url = PlaceSearch.url(for: "Saint John's")
        XCTAssertEqual(url.host, "geocoding-api.open-meteo.com")
        XCTAssertTrue(url.absoluteString.contains("name=Saint%20John's"))
        let search = PlaceSearch(loader: { _ in XCTFail("should not fetch"); throw URLError(.badURL) })
        let none = try await search.search(" a ")
        XCTAssertEqual(none, [])
    }

    func testSavedPlaceRoundTrips() throws {
        let p = SavedPlace(name: "Work", detail: "Ontario, Canada", coordinate: Coordinate(latitude: 43.7, longitude: -79.4))
        let back = try JSONDecoder().decode([SavedPlace].self, from: JSONEncoder().encode([p]))
        XCTAssertEqual(back, [p])
    }
}
