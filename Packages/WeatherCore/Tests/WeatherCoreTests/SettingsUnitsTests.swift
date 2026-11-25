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
        XCTAssertEqual(WeatherFormat.distance(0.74, unit: .km), "740 m")
        XCTAssertEqual(WeatherFormat.distance(0.001, unit: .km), "1 m")
        XCTAssertEqual(WeatherFormat.distance(1.5, unit: .mi), "0.9 miles")
        XCTAssertEqual(WeatherFormat.distance(0.08, unit: .mi), "260 ft")
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

    func testPresets() {
        XCTAssertEqual(UnitPreset.us.settings, UnitSettings(temperature: .fahrenheit, wind: .mph, precipitation: .inches, pressure: .inHg, distance: .mi))
        XCTAssertEqual(UnitPreset.canadian.settings, UnitSettings())
        XCTAssertEqual(UnitPreset.uk.settings.wind, .mph)
        XCTAssertEqual(UnitPreset.uk.settings.pressure, .mb)
        XCTAssertEqual(UnitSettings().preset, .canadian)
        XCTAssertNil(UnitSettings(temperature: .fahrenheit).preset)
        XCTAssertEqual(UnitPreset.forRegion("US"), .us)
        XCTAssertEqual(UnitPreset.forRegion("gb"), .uk)
        XCTAssertEqual(UnitPreset.forRegion("CA"), .canadian)
        XCTAssertEqual(UnitPreset.forRegion(nil), .canadian)
        XCTAssertEqual(WeatherFormat.pressure(1013.25, unit: .mb), "1013 mb")
        XCTAssertEqual(UnitPreset.uk.detail, "°C · mph · mm · mi · mb")
    }

    func testSavesAndRemembersChoice() {
        let defaults = UserDefaults(suiteName: "SettingsUnitsSave")!
        defaults.removePersistentDomain(forName: "SettingsUnitsSave")
        XCTAssertFalse(UnitSettings.hasSaved(in: defaults))
        UnitPreset.us.settings.save(to: defaults)
        XCTAssertTrue(UnitSettings.hasSaved(in: defaults))
        XCTAssertEqual(UnitSettings.load(from: defaults), UnitPreset.us.settings)
    }

    func testRoughDistances() {
        XCTAssertEqual(WeatherFormat.roughDistance(2.9, unit: .km), "3 km")
        XCTAssertEqual(WeatherFormat.roughDistance(0.44, unit: .km), "400 m")
        XCTAssertEqual(WeatherFormat.roughDistance(0.004, unit: .km), "1 m")
        XCTAssertEqual(WeatherFormat.roughDistance(2.0, unit: .mi), "1.2 miles")
        XCTAssertEqual(WeatherFormat.roughDistance(1.6, unit: .mi), "1 mile")
        XCTAssertEqual(WeatherFormat.roughDistance(25.2, unit: .mi), "16 miles")
        XCTAssertEqual(WeatherFormat.roughDistance(0.05, unit: .mi), "200 ft")
        XCTAssertEqual(WeatherFormat.rainAmount(0.4, unit: .metric), "0.4 mm")
        XCTAssertEqual(WeatherFormat.rainAmount(2.54, unit: .inches), "0.10 in")
        XCTAssertEqual(WeatherFormat.snowAmount(1.2, unit: .metric), "1.2 cm")
        XCTAssertEqual(WeatherFormat.snowAmount(2.54, unit: .inches), "1.00 in snow")
    }

    func testParsesPressureAndGusts() throws {
        let json = #"{"latitude":43.5,"longitude":-79.9,"timezone":"America/Toronto","current":{"time":1794580000,"temperature_2m":2.0,"pressure_msl":1009.4,"wind_gusts_10m":31.0}}"#
        let f = try OpenMeteoProvider.parse(Data(json.utf8), fetchedAt: Date())
        XCTAssertEqual(f.current.pressure, 1009.4)
        XCTAssertEqual(f.current.windGusts, 31)
    }
}
