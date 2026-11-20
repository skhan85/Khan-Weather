import XCTest
@testable import WeatherCore

final class PollenIndexTests: XCTestCase {
    func testKeepsInSeasonTypesAndPlants() throws {
        let json = """
        {"regionCode": "CA", "dailyInfo": [{
          "pollenTypeInfo": [
            {"code": "GRASS", "displayName": "Grass", "inSeason": true,
             "indexInfo": {"code": "UPI", "value": 2, "category": "Low"}},
            {"code": "TREE", "displayName": "Tree", "inSeason": true,
             "indexInfo": {"code": "UPI", "value": 4, "category": "High"}},
            {"code": "WEED", "displayName": "Weed", "inSeason": false}
          ],
          "plantInfo": [
            {"code": "BIRCH", "displayName": "Birch", "inSeason": true,
             "indexInfo": {"value": 3, "category": "Moderate"}},
            {"code": "GRAMINALES", "displayName": "Grass", "inSeason": true,
             "indexInfo": {"value": 2, "category": "Low"}},
            {"code": "OAK", "displayName": "Oak", "inSeason": true, "indexInfo": {"value": 0, "category": "None"}}
          ]
        }]}
        """.data(using: .utf8)!
        let list = try PollenIndexProvider.parse(json)
        XCTAssertEqual(list.map(\.name), ["Tree", "Grass", "Birch"])
        XCTAssertEqual(list.first?.category, "High")
    }

    func testOutOfSeasonIsEmpty() throws {
        let json = #"{"dailyInfo": [{"pollenTypeInfo": [{"code": "TREE", "displayName": "Tree", "inSeason": false}]}]}"#
        XCTAssertEqual(try PollenIndexProvider.parse(json.data(using: .utf8)!), [])
        XCTAssertEqual(PollenIndexProvider.url.absoluteString, "https://weather-relay.khanofmilton.ca/v1/pollen")
    }
}
