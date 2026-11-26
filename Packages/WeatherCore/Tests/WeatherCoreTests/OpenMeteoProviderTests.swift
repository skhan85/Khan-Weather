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
        // Hours already past use the first day's weights of the spot's region.
        let region = BlendRegion.at(.fallback)
        let wHRRR = ModelBlend.weight(.usHighRes, leadHours: -1, region: region)
        let wECMWF = ModelBlend.weight(.europe, leadHours: -1, region: region)
        let expected: Double = wHRRR + wECMWF > 0 ? (-5.0 * wHRRR - 3.0 * wECMWF) / (wHRRR + wECMWF) : -4.0
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
        XCTAssertEqual(try XCTUnwrap(Forecast.blendedTemperature(temps, at: quarterPast)), 4.5, accuracy: 0.001)
        XCTAssertEqual(Forecast.blendedTemperature(temps, at: Date(timeIntervalSince1970: TimeInterval(t0))), 4)
        XCTAssertNil(Forecast.blendedTemperature(temps, at: Date(timeIntervalSince1970: TimeInterval(t0 + 4500))))

        var forecast = try OpenMeteoProvider.parse(Self.sample, fetchedAt: Date())
        forecast.current.time = quarterPast
        let blended = forecast.applying(temps)
        XCTAssertEqual(blended.current.temperature, 4.5, accuracy: 0.001)
        XCTAssertEqual(blended.current.feelsLikeKind, .windChill, "feels like follows the blended temperature")
        XCTAssertEqual(blended.current.feelsLike,
                       try XCTUnwrap(EnvironmentCanadaProvider.windChill(temperature: 4.5, windKmh: 19.4)), accuracy: 0.001)
    }

    func testRainOrSnowFromAllTheModels() {
        // Best match alone says rain at 0.6°, but four of five wet models say snow.
        let precip: [WeatherModel: Double] = [.canada: 1, .europe: 0.8, .germany: 0.6, .uk: 0.5, .us: 0.4, .europeAI: 0]
        let snow: [WeatherModel: Double] = [.canada: 1.2, .europe: 1.0, .germany: 0.7, .uk: 0, .us: 0.5, .europeAI: 0]
        XCTAssertEqual(ModelBlend.precipitationType(temperature: 0.6, precipitation: precip, snowfall: snow), .snow)
        // Clearly warm or cold, the temperature decides whatever the models' snowfall says.
        XCTAssertEqual(ModelBlend.precipitationType(temperature: 3.2, precipitation: precip, snowfall: snow), .rain)
        XCTAssertEqual(ModelBlend.precipitationType(temperature: -2.5, precipitation: precip, snowfall: [:]), .snow)
        // No wet model: snow at or below 1°.
        XCTAssertEqual(ModelBlend.precipitationType(temperature: 0.9, precipitation: [:], snowfall: [:]), .snow)
        XCTAssertEqual(ModelBlend.precipitationType(temperature: 1.4, precipitation: [:], snowfall: [:]), .rain)

        var hour = HourlyForecast(time: Date(), temperature: 0.6, precipitation: 1.4, condition: .rainShowers)
        hour.rain = 1.4
        hour.snowfall = 0
        hour.setPrecipitationType(.snow)
        XCTAssertEqual(hour.condition, .snowShowers)
        XCTAssertEqual(hour.rain, 0)
        XCTAssertEqual(hour.snowfall ?? 0, 2.0, accuracy: 0.001, "1.4 mm of water is 2 cm of snow")
        XCTAssertEqual(hour.precipitationKind, .snow)
        hour.setPrecipitationType(.rain)
        XCTAssertEqual(hour.condition, .rainShowers)
        XCTAssertEqual(hour.rain ?? 0, 1.4, accuracy: 0.001)
        var ice = HourlyForecast(time: Date(), temperature: -0.5, precipitation: 1, condition: .freezingRain)
        ice.setPrecipitationType(.snow)
        XCTAssertEqual(ice.condition, .freezingRain, "freezing rain is left alone")
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

    /// A made-up region with the first (Pearson and Hamilton) weights for ICON and ECMWF.
    static let testRegion = BlendRegion(
        id: "test", name: "Test", boxes: [], useBlend: true, models: [.germany, .europe],
        byDay: [[.germany: 0.30, .europe: 0.20], [.germany: 0.22, .europe: 0.04], [.germany: 0.18, .europe: 0.075],
                [.germany: 0.095, .europe: 0.085], [.germany: 0.07, .europe: 0.075], [.germany: 0.06, .europe: 0.165]])

    func testBlendWeightsShiftWithLeadTime() throws {
        let r = Self.testRegion
        let values: [WeatherModel: Double] = [.germany: 0, .europe: 10]
        let today: Double = 10 * 0.20 / 0.50                // ICON 0.30, ECMWF 0.20
        let day6: Double = 10 * 0.165 / 0.225               // ICON 0.06, ECMWF 0.165
        let between: Double = 10 * 0.08 / (0.08 + 0.1375)   // halfway between days 3 and 4 at 72 h
        XCTAssertEqual(try XCTUnwrap(ModelBlend.blend(values, leadHours: 6, region: r)), today, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ModelBlend.blend(values, leadHours: 200, region: r)), day6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ModelBlend.blend(values, leadHours: 72, region: r)), between, accuracy: 0.001)
        XCTAssertNil(ModelBlend.blend([:], leadHours: 6))
        XCTAssertNil(ModelBlend.blend([.bestMatch: 5], leadHours: 6), "best match isn't part of the blend")
    }

    func testBlendFailureKeepsDefault() async throws {
        let provider = OpenMeteoProvider(loader: { request in
            // Every blend request fails: the region's models, then the worldwide retry.
            let isBlend = request.url!.query!.contains("models=")
            return (Self.sample, HTTPURLResponse(url: request.url!, statusCode: isBlend ? 500 : 200,
                                                 httpVersion: nil, headerFields: nil)!)
        })
        let forecast = try await provider.forecast(for: .fallback)
        XCTAssertEqual(forecast.hourly[0].temperature, -2.0)
    }

    func testWMOCodes() {
        XCTAssertEqual(WeatherCondition(wmoCode: 0), .clear)
        XCTAssertEqual(WeatherCondition(wmoCode: 95), .thunderstorm)
        XCTAssertEqual(WeatherCondition(wmoCode: nil), .unknown)
        XCTAssertEqual(WeatherFormat.temperature(-0.3), "0°")
        XCTAssertEqual(WeatherFormat.temperature(21.6), "22°")
    }

    func testRegionalWeightsIsolateLocationsAndTaperWithLead() {
        let milton = Coordinate(latitude: 43.513, longitude: -79.882)
        let london = Coordinate(latitude: 51.5, longitude: -0.12)
        ModelBlend.setRegionalWeights(["germany": 0.9, "europeAI": 0.1], for: milton)
        ModelBlend.setRegionalWeights(["europe": 0.9, "uk": 0.1], for: london)

        let miltonDay0 = ModelBlend.weight(.germany, leadHours: 12, region: .at(milton), coordinate: milton)
        let londonDay0 = ModelBlend.weight(.germany, leadHours: 12, region: .at(milton), coordinate: london)
        XCTAssertNotEqual(miltonDay0, londonDay0)

        let baselineDay6 = ModelBlend.weight(.germany, leadHours: 150, region: .at(milton))
        let miltonDay6 = ModelBlend.weight(.germany, leadHours: 150, region: .at(milton), coordinate: milton)
        XCTAssertGreaterThan(miltonDay6, baselineDay6)
    }

    func testEnsemblePrecipitationMeanReplacesSingleModelSpike() async throws {
        let blend = """
        {
          "hourly": { "time": [1762952400],
                      "temperature_2m_gfs_seamless": [6.0], "temperature_2m_ecmwf_ifs025": [6.0],
                      "temperature_2m_icon_seamless": [6.0], "temperature_2m_gem_seamless": [6.0],
                      "precipitation_gfs_seamless": [0.4], "precipitation_ecmwf_ifs025": [0.4],
                      "precipitation_icon_seamless": [0.4], "precipitation_gem_seamless": [0.4],
                      "snowfall_gfs_seamless": [0.0], "snowfall_ecmwf_ifs025": [0.0],
                      "snowfall_icon_seamless": [0.0], "snowfall_gem_seamless": [0.0] }
        }
        """.data(using: .utf8)!
        let provider = OpenMeteoProvider(loader: { request in
            let isBlend = request.url!.query!.contains("models=")
            return (isBlend ? blend : Self.sample,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let forecast = try await provider.forecast(for: .fallback)
        XCTAssertEqual(try XCTUnwrap(forecast.hourly[0].precipitation), 0.4, accuracy: 0.001)
    }

    func testRegionSummaryMentionsRegionName() {
        let summary = BlendRegion.summary(at: Coordinate(latitude: 51.5, longitude: -0.12))
        XCTAssertTrue(summary.contains("Europe"))
        XCTAssertFalse(summary.contains("Milton"))
    }

    func testMixedTransitionPreservesBothRainAndSnow() {
        let precip: [WeatherModel: Double] = [.canadaHighRes: 1.0, .europeHighRes: 1.0]
        let snow: [WeatherModel: Double] = [.canadaHighRes: 1.0, .europeHighRes: 0.0]
        let share = ModelBlend.precipitationSnowShare(temperature: 1.0, precipitation: precip, snowfall: snow)
        XCTAssertEqual(ModelBlend.precipitationType(temperature: 1.0, precipitation: precip, snowfall: snow), .mixed)
        var hour = HourlyForecast(time: Date(), temperature: 1.0, precipitation: 1.4, condition: .rain)
        hour.setPrecipitationType(.mixed, snowShare: share)
        XCTAssertEqual(hour.rain ?? 0, 0.7, accuracy: 0.01)
        XCTAssertEqual(hour.snowfall ?? 0, 1.0, accuracy: 0.01)
        XCTAssertTrue(hour.isMixedPrecipitation)
    }

    func testGoogleHourlyBlendsIntoForecastHours() throws {
        var f = try OpenMeteoProvider.parse(Self.sample, fetchedAt: Date())
        let t0 = f.hourly[0].time.timeIntervalSince1970
        let gh = RelayGoogleHourly(generated: t0, provider: "Google Weather",
                                   hours: [RelayGoogleHourly.Hour(epoch: t0, temp: 2.0, feels_like: nil,
                                                                  dew_point: nil, wind_kmh: nil, gust_kmh: nil,
                                                                  pop: nil, precip_mm: nil, snow_mm: nil)])
        let blended = f.applyingGoogleHourly(gh)
        // Sample hour[0] is -2.0°C; 0.85 * (-2.0) + 0.15 * 2.0 = -1.4°C
        XCTAssertEqual(blended.hourly[0].temperature, -1.4, accuracy: 0.001)

        // When Google covers current.time (between two hours), current.temperature is blended too.
        let t1 = t0 + 3600
        var fMid = f
        fMid.current.time = Date(timeIntervalSince1970: t0 + 1800) // halfway between t0 and t1
        fMid.current.temperature = 0.0
        let gh2 = RelayGoogleHourly(generated: t0, provider: "Google Weather",
                                    hours: [
                                        RelayGoogleHourly.Hour(epoch: t0, temp: 2.0, feels_like: nil, dew_point: nil, wind_kmh: nil, gust_kmh: nil, pop: nil, precip_mm: nil, snow_mm: nil),
                                        RelayGoogleHourly.Hour(epoch: t1, temp: 6.0, feels_like: nil, dew_point: nil, wind_kmh: nil, gust_kmh: nil, pop: nil, precip_mm: nil, snow_mm: nil),
                                    ])
        // Interpolated Google at midpoint is 4.0°C -> 0.85 * 0.0 + 0.15 * 4.0 = 0.6°C
        XCTAssertEqual(fMid.applyingGoogleHourly(gh2).current.temperature, 0.6, accuracy: 0.001)
    }

    func testImplausibleHomeStationAnchorDoesNotSkewBlend() throws {
        let t0 = 1762952400
        let blend = """
        {
          "hourly": { "time": [\(t0), \(t0 + 3600)],
                      "temperature_2m_gem_hrdps_continental": [2.0, 2.0],
                      "temperature_2m_icon_seamless": [10.0, 10.0],
                      "temperature_2m_ecmwf_aifs025_single": [2.0, 2.0] }
        }
        """.data(using: .utf8)!
        let sunBakedAnchor = ModelBlend.Anchor(temperature: 14.0, time: Date(timeIntervalSince1970: TimeInterval(t0)), isHomeStation: true)
        let noAnchor = try OpenMeteoProvider.parseBlend(blend, region: .home, anchor: nil, now: Date(timeIntervalSince1970: TimeInterval(t0)))
        let withBadAnchor = try OpenMeteoProvider.parseBlend(blend, region: .home, anchor: sunBakedAnchor, now: Date(timeIntervalSince1970: TimeInterval(t0)))
        XCTAssertEqual(withBadAnchor.hourly[t0]!.temperature, noAnchor.hourly[t0]!.temperature, accuracy: 0.001)
    }

    func testDailyExtremesRecoverTimingAttenuationAndGooglePreservesLaterDays() throws {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        let day0 = c.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let day6 = day0.addingTimeInterval(6 * 86400)
        var hours: [HourlyForecast] = []
        var temps = OpenMeteoProvider.ModelTemperatures()
        temps.region = Self.testRegion
        temps.now = day0
        for (dayIdx, baseDay) in [day0, day6].enumerated() {
            for h in 0..<24 {
                let t = baseDay.addingTimeInterval(Double(h) * 3600)
                // Germany bottoms at 01:00 (-2°) & peaks at 12:00 (8°); Europe bottoms at 06:00 (-2°) & peaks at 16:00 (8°); else 3°.
                let gTemp = h == 1 ? -2.0 : (h == 12 ? 8.0 : 3.0)
                let eTemp = h == 6 ? -2.0 : (h == 16 ? 8.0 : 3.0)
                let avg = (gTemp + eTemp) / 2.0
                hours.append(HourlyForecast(time: t, temperature: avg, condition: .overcast))
                temps.hourly[Int(t.timeIntervalSince1970)] = .init(
                    temperature: avg, feelsLike: nil, low: min(gTemp, eTemp), high: max(gTemp, eTemp),
                    count: 2, wet: 0, freezing: 0,
                    modelTemperatures: [.germany: gTemp, .europe: eTemp]
                )
            }
            _ = dayIdx
        }
        let forecast = Forecast(
            location: .fallback, timeZoneIdentifier: "America/Toronto",
            current: CurrentConditions(time: day0, temperature: 3, feelsLike: 3, feelsLikeKind: .apparent, condition: .overcast, isDay: false),
            hourly: hours,
            daily: [
                DailyForecast(date: day0, high: 5, low: 0, condition: .overcast),
                DailyForecast(date: day6, high: 5, low: 0, condition: .overcast),
            ],
            source: "test", fetchedAt: day0
        ).applying(temps)

        // Offset troughs/peaks give raw blended min=0.5 (-2 and 3 averaged) and max=5.5 (8 and 3 averaged),
        // while each model reached low=-2.0 and high=8.0. Full high lift -> 8.0 + 0.4 = 8.4; half low drop -> 0.5 - 1.25 - 0.5 = -1.25.
        XCTAssertEqual(forecast.daily[0].high, 8.4, accuracy: 0.001)
        XCTAssertEqual(forecast.daily[0].low, -1.25, accuracy: 0.001)
        XCTAssertEqual(forecast.daily[1].high, 8.4, accuracy: 0.001)
        XCTAssertEqual(forecast.daily[1].low, -1.25, accuracy: 0.001)

        // Applying Google on day 0 (first 24h) updates day 0 (scaling phase offsets by 0.65) and leaves day 6 untouched.
        let gh = RelayGoogleHourly(
            generated: day0.timeIntervalSince1970, provider: "Google Weather",
            hours: (0..<24).map { h in
                let epoch = day0.addingTimeInterval(Double(h) * 3600).timeIntervalSince1970
                return RelayGoogleHourly.Hour(epoch: epoch, temp: 3.0, feels_like: nil, dew_point: nil,
                                              wind_kmh: nil, gust_kmh: nil, pop: nil, precip_mm: nil, snow_mm: nil)
            }
        )
        let withGoogle = forecast.applyingGoogleHourly(gh)
        // Day 6 was beyond 48h and untouched by Google -> keeps exact phase-recovered extremes.
        XCTAssertEqual(withGoogle.daily[1].high, 8.4, accuracy: 0.001)
        XCTAssertEqual(withGoogle.daily[1].low, -1.25, accuracy: 0.001)
        // Day 0 hourly min after 15% Google @ 3.0° becomes 0.85*0.5 + 0.15*3.0 = 0.875; phaseLowDrop scales by 0.85 (1.0625).
        XCTAssertEqual(withGoogle.daily[0].low, 0.875 - 1.0625 - 0.5, accuracy: 0.001)
    }
}
