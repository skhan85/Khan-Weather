import XCTest
@testable import WeatherCore

final class ChanceOfRainTests: XCTestCase {
    func testHourlyChanceIsHalfOpenMeteoHalfModelShare() {
        XCTAssertEqual(ModelBlend.hourlyChance(openMeteo: 40, wet: 3, of: 4), 58)   // (40 + 75) / 2
        XCTAssertEqual(ModelBlend.hourlyChance(openMeteo: 10, wet: 0, of: 8), 5)
        XCTAssertEqual(ModelBlend.hourlyChance(openMeteo: nil, wet: 2, of: 8), 25)
        XCTAssertEqual(ModelBlend.hourlyChance(openMeteo: 40, wet: 3, of: 3), 40, "too few models: keep Open-Meteo's")
    }

    func testDailyChanceLeansOnModelsTodayAndTomorrow() {
        // Today/tomorrow: 1/4 Open-Meteo, 3/4 the share of wet models.
        XCTAssertEqual(ModelBlend.dailyChance(openMeteo: 20, wet: 6, of: 8, dayIndex: 0), 61)   // 5 + 56.25
        XCTAssertEqual(ModelBlend.dailyChance(openMeteo: 20, wet: 6, of: 8, dayIndex: 1), 61)
        // Later: half and half.
        XCTAssertEqual(ModelBlend.dailyChance(openMeteo: 20, wet: 6, of: 8, dayIndex: 3), 48)   // 10 + 37.5
        XCTAssertEqual(ModelBlend.dailyChance(openMeteo: 80, wet: 1, of: 3, dayIndex: 0), 80)
    }

    func testBlendSetsHourlyChanceFromWetModels() async throws {
        // Four models at the first hour, three of them wet (>= 0.2 mm).
        let blend = """
        {
          "hourly": { "time": [1762952400],
                      "temperature_2m_gfs_hrrr": [-2.0], "temperature_2m_gfs_seamless": [-2.0],
                      "temperature_2m_icon_seamless": [-2.0], "temperature_2m_ukmo_seamless": [-2.0],
                      "precipitation_gfs_hrrr": [0.5], "precipitation_gfs_seamless": [0.3],
                      "precipitation_icon_seamless": [0.2], "precipitation_ukmo_seamless": [0.0] }
        }
        """.data(using: .utf8)!
        let provider = OpenMeteoProvider(loader: { request in
            let isBlend = request.url!.query!.contains("gem_hrdps_continental")
            return (isBlend ? blend : OpenMeteoProviderTests.sample,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let forecast = try await provider.forecast(for: .fallback)
        XCTAssertEqual(forecast.hourly[0].modelsWet, 3)
        XCTAssertEqual(forecast.hourly[0].precipitationProbability, 58, "(40% + 75%) / 2")
        XCTAssertEqual(forecast.hourly[1].precipitationProbability, 55, "an hour without models keeps Open-Meteo's")
        XCTAssertEqual(forecast.daily[0].precipitationProbability, 80, "a day the models don't cover keeps Open-Meteo's")
    }
}
