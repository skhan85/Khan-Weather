import XCTest
@testable import WeatherCore

final class NetatmoRelayTests: XCTestCase {
    let milton = Coordinate(latitude: 43.513, longitude: -79.882)
    let now = Date(timeIntervalSince1970: 1794581000)

    let sample = #"""
    {"generated":1794580900,"stations":[
      {"lat":43.5142,"lon":-79.8845,"distance_km":0.74,"city":"Milton","altitude":192,"temperature":1.8,"observed":1794580705,"humidity":95,"pressure":1007.4},
      {"lat":43.52,"lon":-79.84,"distance_km":3.5,"city":"Milton","temperature":2.4,"observed":1794580600,"humidity":79,"wind_strength":10,"wind_angle":223,"gust_strength":19},
      {"lat":43.505,"lon":-79.87,"distance_km":1.3,"city":"Milton","temperature":9.9,"observed":1794580650,"humidity":60},
      {"lat":43.58,"lon":-79.77,"distance_km":11,"city":"Mississauga","temperature":4,"observed":1794580700,"humidity":72},
      {"lat":43.511,"lon":-79.88,"city":"Milton","temperature":-5,"observed":1794570000}
    ]}
    """#

    func testMedianOfNearestThree() throws {
        let o = try XCTUnwrap(NetatmoRelayProvider.parse(Data(sample.utf8), near: milton, now: now, radiusKm: 5, maxAge: 3600))
        // The 9.9 (sunny sensor) is dropped as an outlier; 1.8 and 2.4 remain -> 2.1.
        XCTAssertEqual(o.temperature, 2.1)
        XCTAssertEqual(o.humidity ?? 0, 87, accuracy: 0.01)
        XCTAssertEqual(o.windSpeed, 10)
        XCTAssertEqual(o.stationName, "2 Netatmo stations in Milton")
        XCTAssertEqual(o.dataProvider, "NETATMO")
        XCTAssertEqual(o.distanceKm ?? 0, 0.27, accuracy: 0.1)
    }

    func testNothingNearby() throws {
        let far = Coordinate(latitude: 45, longitude: -75)
        XCTAssertNil(try NetatmoRelayProvider.parse(Data(sample.utf8), near: far, now: now, radiusKm: 5, maxAge: 3600))
    }

    func testMergeKeepsOfficialSky() {
        var official = Observation(stationName: "Toronto Pearson", observedAt: now, temperature: 3, humidity: 70,
                                   windSpeed: 20, windDirection: 270, condition: .rain, conditionText: "Light Rain", distanceKm: 25)
        official.dataProvider = "ON-MTO"
        let local = Observation(stationName: "2 Netatmo stations in Milton", observedAt: now, temperature: 2, humidity: 90, distanceKm: 0.5)
        let merged = HyperlocalObservationProvider.merge(official: official, netatmo: local)
        XCTAssertEqual(merged.temperature, 2)
        XCTAssertEqual(merged.condition, .rain)
        XCTAssertEqual(merged.skyStationName, "Toronto Pearson")
        XCTAssertEqual(merged.skyDataProvider, "ON-MTO")
        XCTAssertNil(merged.windSpeed)   // Pearson is too far to speak for local wind
    }

    func testOfficialLocalStationWinsWhenFarApart() {
        let official = Observation(stationName: "CR-27 Campbellville", observedAt: now, temperature: 3, distanceKm: 8)
        let warm = Observation(stationName: "2 Netatmo stations in Milton", observedAt: now, temperature: 6.5, distanceKm: 1)
        XCTAssertEqual(HyperlocalObservationProvider.merge(official: official, netatmo: warm).stationName, "CR-27 Campbellville")
        let close = Observation(stationName: "2 Netatmo stations in Milton", observedAt: now, temperature: 4, distanceKm: 1)
        XCTAssertEqual(HyperlocalObservationProvider.merge(official: official, netatmo: close).temperature, 4)
    }
}
