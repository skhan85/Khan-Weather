import XCTest
@testable import WeatherCore

final class ModelComparisonTests: XCTestCase {
    func testParsesSuffixedModels() throws {
        let json = #"""
        {"daily":{"time":[1794546000,1794632400],
          "weather_code_best_match":[3,61],"temperature_2m_max_best_match":[3.2,6.1],"temperature_2m_min_best_match":[-0.4,1.0],
          "rain_sum_best_match":[0,4.2],"showers_sum_best_match":[0,0.3],"snowfall_sum_best_match":[0,0],
          "weather_code_gem_seamless":[3,63],"temperature_2m_max_gem_seamless":[2.9,5.5],"temperature_2m_min_gem_seamless":[-1.0,0.8],
          "rain_sum_gem_seamless":[0,6],"showers_sum_gem_seamless":[null,null],"snowfall_sum_gem_seamless":[0,0],
          "weather_code_gfs_seamless":[2,61],"temperature_2m_max_gfs_seamless":[4.0,7.9],"temperature_2m_min_gfs_seamless":[0.1,2.0],
          "weather_code_ecmwf_ifs025":[3,null],"temperature_2m_max_ecmwf_ifs025":[3.5,null],"temperature_2m_min_ecmwf_ifs025":[0.0,null],
          "weather_code_icon_seamless":[3,61],"temperature_2m_max_icon_seamless":[3.1,6.4],"temperature_2m_min_icon_seamless":[-0.2,1.1]}}
        """#
        let days = try ModelComparisonProvider.parse(Data(json.utf8))
        XCTAssertEqual(days.count, 9, "ECMWF's missing second day is dropped")
        let gemDay2 = try XCTUnwrap(days.first { $0.model == .canada && $0.date.timeIntervalSince1970 == 1794632400 })
        XCTAssertEqual(gemDay2.high, 5.5)
        XCTAssertEqual(gemDay2.rainMm, 6)
        XCTAssertEqual(gemDay2.condition, .rain)
        let best = try XCTUnwrap(days.first { $0.model == .bestMatch && $0.date.timeIntervalSince1970 == 1794632400 })
        XCTAssertEqual(best.rainMm ?? 0, 4.5, accuracy: 0.001)
    }
}
