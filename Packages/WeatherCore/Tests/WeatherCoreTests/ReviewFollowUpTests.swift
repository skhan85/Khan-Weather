import XCTest
@testable import WeatherCore

final class ReviewFollowUpTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    func flatForecast(temperature: Double = 2, wind: Double = 20, isDay: Bool = true) -> Forecast {
        let hours = (0..<8).map { i in
            var h = HourlyForecast(time: t0.addingTimeInterval(Double(i) * 3600), temperature: temperature,
                                   feelsLike: temperature, condition: .overcast)
            h.windSpeed = wind
            h.windGusts = wind + 15
            return h
        }
        return Forecast(location: .fallback, timeZoneIdentifier: "America/Toronto",
                        current: CurrentConditions(time: t0, temperature: temperature, feelsLike: temperature,
                                                   feelsLikeKind: .apparent, windSpeed: wind, condition: .overcast,
                                                   isDay: isDay),
                        hourly: hours, daily: [], source: "t", fetchedAt: t0)
    }

    // MARK: Blend

    func testModelValuesReadAtTheMinuteOfTheReading() {
        let times: [Double] = [0, 3600, 7200]
        let series: [WeatherModel: [Double?]] = [.canada: [10, 4, 2], .us: [8, 8, nil]]
        let at40 = OpenMeteoProvider.valuesAt(2400, times: times, series: series)
        XCTAssertEqual(at40[.canada]!, 6, accuracy: 0.001)   // two thirds of the way from 10 to 4
        XCTAssertEqual(at40[.us]!, 8, accuracy: 0.001)
        // Past the last hour: the last value, and a model missing it falls back to the hour before.
        let late = OpenMeteoProvider.valuesAt(9000, times: times, series: series)
        XCTAssertEqual(late[.canada], 2)
        XCTAssertNil(late[.us])
    }

    func testOneReadingDoesNotHandAModelTheWholeBlend() {
        // One model 0.3° off the reading and one 1.5° off.
        // At lead 0 their priors are 0.30 and 0.20 (a test region with the first weights).
        let values: [WeatherModel: Double] = [.germany: 10, .europe: 12]
        let now: [WeatherModel: Double] = [.germany: 5.3, .europe: 6.5]
        let blended = ModelBlend.blend(values, leadHours: 0, region: OpenMeteoProviderTests.testRegion,
                                       observedTemperature: 5, currentModelTemps: now)!
        // Fully live at lead 0: weights ∝ prior / (err² + 2), about 75/25, so ≈ 10.5. With
        // err² + 0.5 it would be 88/12 (≈ 10.24).
        XCTAssertGreaterThan(blended, 10.4)
        XCTAssertLessThan(blended, 11.9)
    }

    // MARK: Now

    func testHomeWindDoesNotSteerTheHours() {
        var o = Observation(stationName: "Netatmo", observedAt: t0, temperature: 2, windSpeed: 3, distanceKm: 1)
        o.dataProvider = "NETATMO"
        o.windGusts = 5
        let nudged = flatForecast().applying(o)
        XCTAssertEqual(nudged.hourly[1].windSpeed, 20)
        XCTAssertEqual(nudged.hourly[1].windGusts, 35)
        XCTAssertEqual(nudged.current.windSpeed, 3, "the Now card still shows the home reading")

        var official = Observation(stationName: "Campbellville", observedAt: t0, temperature: 2, windSpeed: 8, distanceKm: 6)
        official.dataProvider = "ON-MTO"
        XCTAssertLessThan(flatForecast().applying(official).hourly[1].windSpeed!, 20)
    }

    func testHomeStationsAFewDegreesAboveTheModelCountAtNight() {
        var o = Observation(stationName: "Netatmo", observedAt: t0, temperature: 5.5, distanceKm: 1)
        o.dataProvider = "NETATMO"
        o.stationTemperatures = [5.5, 5.2, 5.8]
        // 3.5° above a 2° forecast: set aside by day, kept at night.
        XCTAssertEqual(flatForecast(isDay: true).applying(o).current.temperature, 2)
        XCTAssertEqual(flatForecast(isDay: false).applying(o).current.temperature, 5.5, accuracy: 0.01)
    }

    func testLastHoursRainAloneIsNotRainNow() {
        var f = flatForecast(temperature: 6)
        f.minutely = [PrecipitationSlot(time: t0, precipitation: 0), PrecipitationSlot(time: t0.addingTimeInterval(900), precipitation: 0)]
        var o = Observation(stationName: "Milton", observedAt: t0, temperature: 6, distanceKm: 3)
        o.rainGauges = 1
        o.rainLastHourMm = 1.2
        f.observation = o
        XCTAssertNil(f.nowcast(at: t0))
    }

    func testSavedForecastRollsNowForward() {
        var f = flatForecast()
        f.hourly[3].temperature = -4
        f.observation = Observation(stationName: "X", observedAt: t0, temperature: 9, distanceKm: 1)
        let later = f.rolledForward(to: t0.addingTimeInterval(3 * 3600 + 600))
        XCTAssertEqual(later.current.temperature, -4)
        XCTAssertNil(later.observation)
        XCTAssertEqual(f.rolledForward(to: t0.addingTimeInterval(600)), f, "within the hour, unchanged")
    }

    func testGustsFromNowCountForWhatToWear() {
        var current = flatForecast().current
        current.windGusts = 60
        let calm = (1...3).map { i -> HourlyForecast in
            var h = HourlyForecast(time: t0.addingTimeInterval(Double(i) * 3600), temperature: 15, feelsLike: 15,
                                   condition: .clear)
            h.windGusts = 20
            return h
        }
        XCTAssertTrue(WhatToWear.tip(current: current, upcoming: calm, hourText: { _ in "" }).contains("windproof"))
    }

    // MARK: Air quality

    func testAQHIPeakIsForTheRestOfToday() {
        let tz = TimeZone(identifier: "America/Toronto")!
        // 3 PM, 19 Nov 2026 in Toronto = 20:00 UTC.
        let now = ISO8601DateFormatter().date(from: "2026-11-19T20:00:00Z")!
        let json = """
        {"features": [
          {"geometry": {"type": "Point", "coordinates": [-79.88, 43.52]},
           "properties": {"aqhi": 2, "location_id": "MIL", "forecast_datetime": "2026-11-19T21:00:00Z"}},
          {"geometry": {"type": "Point", "coordinates": [-79.88, 43.52]},
           "properties": {"aqhi": 4, "location_id": "MIL", "forecast_datetime": "2026-11-20T02:00:00Z"}},
          {"geometry": {"type": "Point", "coordinates": [-79.88, 43.52]},
           "properties": {"aqhi": 7, "location_id": "MIL", "forecast_datetime": "2026-11-20T18:00:00Z"}},
          {"geometry": {"type": "Point", "coordinates": [-79.38, 43.65]},
           "properties": {"aqhi": 9, "location_id": "TOR", "forecast_datetime": "2026-11-19T22:00:00Z"}}
        ]}
        """.data(using: .utf8)!
        let peak = AirQualityProvider.parseAQHIForecast(json, near: Coordinate(latitude: 43.518, longitude: -79.877),
                                                        now: now, timeZone: tz)
        XCTAssertEqual(peak, 4, "tomorrow's 7 and Toronto's 9 are left out")
    }
}
