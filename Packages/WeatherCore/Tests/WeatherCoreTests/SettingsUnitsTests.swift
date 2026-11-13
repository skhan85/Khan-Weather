import XCTest
@testable import WeatherCore

final class SettingsUnitsTests: XCTestCase {
    func testPressure() {
        XCTAssertEqual(WeatherFormat.pressure(1013.25, unit: .hPa), "1013 hPa")
        XCTAssertEqual(WeatherFormat.pressure(1013.25, unit: .kPa), "101.3 kPa")
        XCTAssertEqual(WeatherFormat.pressure(1013.25, unit: .inHg), "29.92 inHg")
        XCTAssertNil(WeatherFormat.pressure(nil, unit: .kPa))
    }

    func testDistance() {
        XCTAssertEqual(WeatherFormat.distance(13.4, unit: .km), "13 km")
        XCTAssertEqual(WeatherFormat.distance(0.74, unit: .km), "0.7 km")
        XCTAssertEqual(WeatherFormat.distance(24.14, unit: .mi), "15 miles")
        XCTAssertEqual(WeatherFormat.distance(1.0, unit: .km), "1 km")
    }

    func testLoadsNewUnits() {
        let defaults = UserDefaults(suiteName: "SettingsUnitsTests")!
        defaults.removePersistentDomain(forName: "SettingsUnitsTests")
        XCTAssertEqual(UnitSettings.load(from: defaults).pressure, .kPa)
        defaults.set("inHg", forKey: UnitSettings.pressureKey)
        defaults.set("mi", forKey: UnitSettings.distanceKey)
        let s = UnitSettings.load(from: defaults)
        XCTAssertEqual(s.pressure, .inHg)
        XCTAssertEqual(s.distance, .mi)
    }

    func testParsesPressureAndGusts() throws {
        let json = #"{"latitude":43.5,"longitude":-79.9,"timezone":"America/Toronto","current":{"time":1794580000,"temperature_2m":2.0,"pressure_msl":1009.4,"wind_gusts_10m":31.0}}"#
        let f = try OpenMeteoProvider.parse(Data(json.utf8), fetchedAt: Date())
        XCTAssertEqual(f.current.pressure, 1009.4)
        XCTAssertEqual(f.current.windGusts, 31)
    }
}
