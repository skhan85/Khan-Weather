import XCTest
@testable import WeatherCore

final class OpenMeteoProviderTests: XCTestCase {
    /// Trimmed real-shape response: 3 hours (one with a null temperature) and 2 days.
    static let sample = """
    {
      "latitude": 43.65, "longitude": -79.38, "timezone": "America/Toronto",
      "utc_offset_seconds": -18000,
      "current": {
        "time": 1762956000, "interval": 900,
        "temperature_2m": -2.4, "apparent_temperature": -7.9, "relative_humidity_2m": 81,
        "is_day": 0, "precipitation": 0.1, "weather_code": 71,
        "wind_speed_10m": 19.4, "wind_direction_10m": 280
      },
      "hourly": {
        "time": [1762952400, 1762956000, 1762959600],
        "temperature_2m": [-2.0, -2.4, null],
        "apparent_temperature": [-7.0, -7.9, null],
        "precipitation_probability": [40, 55, 60],
        "weather_code": [3, 71, 73]
      },
      "daily": {
        "time": [1762923600, 1763010000],
        "weather_code": [71, 0],
        "temperature_2m_max": [1.2, 4.0],
        "temperature_2m_min": [-4.1, -3.0],
        "apparent_temperature_max": [-3.0, 0.5],
        "apparent_temperature_min": [-10.2, -8.0],
        "precipitation_probability_max": [80, 5],
        "rain_sum": [1.2, 0], "showers_sum": [0.4, null], "snowfall_sum": [3.1, 0]
      },
      "minutely_15": {
        "time": [1762956000, 1762956900, 1762957800],
        "precipitation": [0.0, 0.3, null],
        "rain": [0.0, 0.0, null],
        "snowfall": [0.0, 0.21, null]
      }
    }
    """.data(using: .utf8)!

    func testParsesCurrentConditions() throws {
        let forecast = try OpenMeteoProvider.parse(Self.sample, fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(forecast.timeZoneIdentifier, "America/Toronto")
        XCTAssertEqual(forecast.current.temperature, -2.4)
        // Environment Canada's wind chill from -2.4° and 19.4 km/h, not Open-Meteo's -7.9.
        XCTAssertEqual(forecast.current.feelsLike, -8.2, accuracy: 0.05)
        XCTAssertEqual(forecast.current.feelsLikeKind, .windChill)
        XCTAssertEqual(forecast.current.condition, .snow)
        XCTAssertFalse(forecast.current.isDay)
        XCTAssertEqual(forecast.current.humidity, 81)
    }

    func testSkipsHoursWithMissingTemperature() throws {
        let forecast = try OpenMeteoProvider.parse(Self.sample, fetchedAt: Date())
        XCTAssertEqual(forecast.hourly.count, 2)
        XCTAssertEqual(forecast.hourly.last?.precipitationProbability, 55)
    }

    func testParsesDaily() throws {
        let forecast = try OpenMeteoProvider.parse(Self.sample, fetchedAt: Date())
        XCTAssertEqual(forecast.daily.count, 2)
        XCTAssertEqual(forecast.daily.first?.high, 1.2)
        XCTAssertEqual(forecast.daily.first?.feelsLikeLow, -10.2)
        XCTAssertEqual(forecast.daily.last?.condition, .clear)
        XCTAssertEqual(try XCTUnwrap(forecast.daily.first?.rainSum), 1.6, accuracy: 0.001)
        XCTAssertEqual(forecast.daily.first?.snowfallSum, 3.1)
        XCTAssertEqual(forecast.daily.last?.rainSum, 0)
    }

    func testParsesMinutely15() throws {
        let forecast = try OpenMeteoProvider.parse(Self.sample, fetchedAt: Date())
        XCTAssertEqual(forecast.minutely.count, 2)
        XCTAssertEqual(forecast.minutely.last?.snowfall, 0.21)
        let url = OpenMeteoProvider().url(for: Coordinate(latitude: 43.5, longitude: -79.9))
        XCTAssertTrue(url.absoluteString.contains("minutely_15=precipitation,rain,snowfall"))
        XCTAssertTrue(url.absoluteString.contains("snowfall_sum"))
    }

    func testRequestUsesRoundedCoordinatesAndAllFields() throws {
        let url = OpenMeteoProvider().url(for: Coordinate(latitude: 43.653226, longitude: -79.383184))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("latitude"), "43.6532")
        XCTAssertEqual(value("longitude"), "-79.3832")
        XCTAssertEqual(value("timezone"), "auto")
        XCTAssertTrue(value("current")!.contains("apparent_temperature"))
        XCTAssertTrue(value("daily")!.contains("apparent_temperature_max"))
    }

    func testHTTPErrorIsThrown() async {
        let provider = OpenMeteoProvider(loader: { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        })
        do {
            _ = try await provider.forecast(for: .fallback)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ForecastError, .httpStatus(429))
        }
    }

    func testFetchUsesLoader() async throws {
        let provider = OpenMeteoProvider(loader: { request in
            (Self.sample, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let forecast = try await provider.forecast(for: .fallback)
        XCTAssertEqual(forecast.source, "Open-Meteo")
    }

    func testNorthAmericaUsesBlendedTemperatures() async throws {
        let blend = """
        {
          "hourly": { "time": [1762952400, 1762956000],
                      "temperature_2m_gfs_hrrr": [-5.0, null],
                      "temperature_2m_ecmwf_ifs025": [-3.0, null],
                      "apparent_temperature_gfs_hrrr": [-9.0, null] }
        }
        """.data(using: .utf8)!
        let provider = OpenMeteoProvider(loader: { request in
            let isBlend = request.url!.query!.contains("gem_hrdps_continental")
            return (isBlend ? blend : Self.sample,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let forecast = try await provider.forecast(for: .fallback)
        // Hours already past use the first day's weights: HRRR 0.15, ECMWF 0.20.
        let expected: Double = (-5.0 * 0.15 - 3.0 * 0.20) / 0.35
        XCTAssertEqual(forecast.hourly[0].temperature, expected, accuracy: 0.001)
        XCTAssertEqual(forecast.hourly[0].feelsLike, -9.0)
        XCTAssertEqual(forecast.hourly[0].modelLow, -5.0)
        XCTAssertEqual(forecast.hourly[0].modelHigh, -3.0)
        XCTAssertEqual(forecast.hourly[0].modelCount, 2)
        XCTAssertEqual(forecast.hourly[0].modelsFreezing, 2)
        XCTAssertEqual(forecast.daily[0].modelSpread, 2.0)
        XCTAssertEqual(forecast.daily[0].confidence, .sure)
        XCTAssertEqual(forecast.hourly[1].temperature, -2.4, "keeps the default where no model has a value")
        XCTAssertEqual(forecast.daily[0].high, 1.2, "a day the blend doesn't fully cover keeps its own high")
    }

    func testNowComesFromTheBlendBetweenHours() throws {
        let t0 = 1762952400
        var temps = OpenMeteoProvider.ModelTemperatures()
        temps.hourly[t0] = .init(temperature: 4, feelsLike: nil, low: 4, high: 4, count: 6, wet: 0, freezing: 0)
        temps.hourly[t0 + 3600] = .init(temperature: 6, feelsLike: nil, low: 6, high: 6, count: 6, wet: 0, freezing: 0)
        let quarterPast = Date(timeIntervalSince1970: TimeInterval(t0 + 900))
        XCTAssertEqual(try XCTUnwrap(OpenMeteoProvider.blendedTemperature(temps, at: quarterPast)), 4.5, accuracy: 0.001)
        XCTAssertEqual(OpenMeteoProvider.blendedTemperature(temps, at: Date(timeIntervalSince1970: TimeInterval(t0))), 4)
        XCTAssertNil(OpenMeteoProvider.blendedTemperature(temps, at: Date(timeIntervalSince1970: TimeInterval(t0 + 4500))))

        var forecast = try OpenMeteoProvider.parse(Self.sample, fetchedAt: Date())
        forecast.current.time = quarterPast
        let blended = forecast.applying(temps)
        XCTAssertEqual(blended.current.temperature, 4.5, accuracy: 0.001)
        XCTAssertEqual(blended.current.feelsLikeKind, .windChill, "feels like follows the blended temperature")
        XCTAssertEqual(blended.current.feelsLike,
                       try XCTUnwrap(EnvironmentCanadaProvider.windChill(temperature: 4.5, windKmh: 19.4)), accuracy: 0.001)
    }

    func testFeelsLikeFollowsEnvironmentCanada() throws {
        // Winter breeze: wind chill.
        let chill = try XCTUnwrap(FeelsLike.value(temperature: 0, windKmh: 20, dewPoint: -3))
        XCTAssertEqual(chill.kind, .windChill)
        XCTAssertEqual(chill.value, -5.2, accuracy: 0.1)
        // Muggy summer day: humidex (Open-Meteo's apparent temperature said about 27°).
        let muggy = try XCTUnwrap(FeelsLike.value(temperature: 25, windKmh: 8, dewPoint: 19))
        XCTAssertEqual(muggy.kind, .humidex)
        XCTAssertEqual(muggy.value, 31.8, accuracy: 0.2)
        // Mild and calm: the air temperature.
        XCTAssertEqual(FeelsLike.value(temperature: 15, windKmh: 3, dewPoint: 5)?.value, 15)
        XCTAssertNil(FeelsLike.value(temperature: 15, windKmh: nil, dewPoint: nil))
    }

    func testBlendWeightsShiftWithLeadTime() throws {
        let values: [WeatherModel: Double] = [.germany: 0, .europe: 10]
        let today: Double = 10 * 0.20 / 0.50                // ICON 0.30, ECMWF 0.20
        let day6: Double = 10 * 0.165 / 0.225               // ICON 0.06, ECMWF 0.165
        let between: Double = 10 * 0.08 / (0.08 + 0.1375)   // halfway between days 3 and 4 at 72 h
        XCTAssertEqual(try XCTUnwrap(ModelBlend.blend(values, leadHours: 6)), today, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ModelBlend.blend(values, leadHours: 200)), day6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ModelBlend.blend(values, leadHours: 72)), between, accuracy: 0.001)
        XCTAssertNil(ModelBlend.blend([:], leadHours: 6))
        XCTAssertNil(ModelBlend.blend([.bestMatch: 5], leadHours: 6), "best match isn't part of the blend")
    }

    func testBlendFailureKeepsDefault() async throws {
        let provider = OpenMeteoProvider(loader: { request in
            let isBlend = request.url!.query!.contains("gem_hrdps_continental")
            return (Self.sample, HTTPURLResponse(url: request.url!, statusCode: isBlend ? 500 : 200,
                                                 httpVersion: nil, headerFields: nil)!)
        })
        let forecast = try await provider.forecast(for: .fallback)
        XCTAssertEqual(forecast.hourly[0].temperature, -2.0)
        XCTAssertFalse(OpenMeteoProvider.usesBlend(Coordinate(latitude: 51.5, longitude: -0.12)))
    }

    func testWMOCodes() {
        XCTAssertEqual(WeatherCondition(wmoCode: 0), .clear)
        XCTAssertEqual(WeatherCondition(wmoCode: 95), .thunderstorm)
        XCTAssertEqual(WeatherCondition(wmoCode: nil), .unknown)
        XCTAssertEqual(WeatherFormat.temperature(-0.3), "0°")
        XCTAssertEqual(WeatherFormat.temperature(21.6), "22°")
    }
}
