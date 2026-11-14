import XCTest
@testable import WeatherCore

final class TextForecastTests: XCTestCase {
    static let sample = """
    {"type": "FeatureCollection", "features": [
      {"geometry": {"type": "Point", "coordinates": [-79.88, 43.52]},
       "properties": {"name": {"en": "Milton"},
         "forecastGroup": {"forecasts": [
           {"period": {"textForecastName": {"en": "Today"}, "value": {"en": "Saturday"}},
            "textSummary": {"en": "Rain beginning near noon. High 6."}},
           {"period": {"textForecastName": {"en": "Tonight"}, "value": {"en": "Saturday night"}},
            "textSummary": {"en": " Rain ending this evening. Low zero. "}},
           {"period": {"textForecastName": {"en": "Sunday"}}, "textSummary": {"en": ""}}
         ]}}},
      {"geometry": {"type": "Point", "coordinates": [-79.38, 43.65]},
       "properties": {"name": {"en": "Toronto"},
         "forecastGroup": {"forecasts": [
           {"period": {"textForecastName": {"en": "Today"}}, "textSummary": {"en": "Cloudy."}}]}}}
    ]}
    """.data(using: .utf8)!

    func testPicksNearestCityWithText() throws {
        let milton = Coordinate(latitude: 43.52, longitude: -79.89)
        let text = try XCTUnwrap(TextForecastProvider.parse(Self.sample, near: milton))
        XCTAssertEqual(text.cityName, "Milton")
        XCTAssertEqual(text.periods.map(\.name), ["Today", "Tonight"], "empty periods are dropped")
        XCTAssertEqual(text.periods[1].text, "Rain ending this evening. Low zero.")
    }

    func testNothingNearby() throws {
        let ottawa = Coordinate(latitude: 45.42, longitude: -75.70)
        XCTAssertNil(try TextForecastProvider.parse(Self.sample, near: ottawa))
    }
}
