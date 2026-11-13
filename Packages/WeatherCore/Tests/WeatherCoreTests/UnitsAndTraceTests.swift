import XCTest
@testable import WeatherCore

final class UnitsAndTraceTests: XCTestCase {
    func testTraceFlurryShowsAsCloud() {
        XCTAssertEqual(WeatherCondition.snow.ignoringTrace(probability: 5, amountMm: 0.1), .overcast)
        XCTAssertEqual(WeatherCondition.snow.ignoringTrace(probability: 40, amountMm: 0.1), .snow, "likely enough to keep")
        XCTAssertEqual(WeatherCondition.rain.ignoringTrace(probability: 5, amountMm: 1.2), .rain, "real amount")
        XCTAssertEqual(WeatherCondition.snow.ignoringTrace(probability: 5, amountMm: nil), .snow, "unknown amount")
        XCTAssertEqual(WeatherCondition.thunderstorm.ignoringTrace(probability: 5, amountMm: 0), .thunderstorm)
    }

    func testParserDemotesTraceHours() throws {
        let json = """
        {"latitude": 43.5, "longitude": -79.9, "timezone": "America/Toronto",
         "current": {"time": 1762956000, "temperature_2m": 1.0, "weather_code": 3},
         "hourly": {"time": [1762956000, 1762959600], "temperature_2m": [1.0, 0.5],
                    "precipitation_probability": [5, 60], "precipitation": [0.1, 0.8], "weather_code": [71, 71]},
         "daily": {"time": [1762923600], "weather_code": [71], "temperature_2m_max": [4], "temperature_2m_min": [0],
                   "precipitation_probability_max": [8], "rain_sum": [0], "showers_sum": [0], "snowfall_sum": [0.07]}}
        """.data(using: .utf8)!
        let f = try OpenMeteoProvider.parse(json, fetchedAt: Date())
        XCTAssertEqual(f.hourly.map(\.condition), [.overcast, .snow])
        XCTAssertEqual(f.daily.first?.condition, .overcast)
    }

    func testConversions() {
        XCTAssertEqual(WeatherFormat.temperature(0, unit: .fahrenheit), "32°")
        XCTAssertEqual(WeatherFormat.temperature(-17.8, unit: .fahrenheit), "0°")
        XCTAssertEqual(WeatherFormat.temperature(-0.4, unit: .celsius), "0°")
        XCTAssertEqual(WeatherFormat.wind(16.1, unit: .mph), "10 mph")
        XCTAssertEqual(WeatherFormat.wind(36, unit: .ms), "10 m/s")
        XCTAssertEqual(WeatherFormat.precipitationTotals(rainMm: 12.7, snowCm: 5.08, unit: .inches), "2.0 in snow, 0.5 in")
        XCTAssertEqual(WeatherFormat.precipitationTotals(rainMm: 3.4, snowCm: 0, unit: .metric), "3 mm")
    }

    func testSettingsRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UnitsTest-\(UUID())"))
        XCTAssertEqual(UnitSettings.load(from: defaults), UnitSettings())
        defaults.set("fahrenheit", forKey: UnitSettings.temperatureKey)
        defaults.set("knots", forKey: UnitSettings.windKey)
        XCTAssertEqual(UnitSettings.load(from: defaults), UnitSettings(temperature: .fahrenheit, wind: .knots))
    }
}
