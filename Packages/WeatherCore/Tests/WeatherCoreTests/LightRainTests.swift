import XCTest
@testable import WeatherCore

/// More ways to tell it's drizzling or raining lightly when the radar shows nothing (27 Nov 2026,
/// Milton: drizzle all morning while the card said "Overcast").
final class LightRainTests: XCTestCase {
    static let milton = Coordinate(latitude: 43.513, longitude: -79.882)

    func forecast(temperature: Double, humidity: Double?) -> Forecast {
        let now = Date()
        let current = CurrentConditions(time: now, temperature: temperature, feelsLike: temperature, feelsLikeKind: .apparent,
                                        humidity: humidity, condition: .overcast, isDay: false)
        var f = Forecast(location: Self.milton, timeZoneIdentifier: "America/Toronto", current: current,
                         hourly: [], daily: [], source: "t", fetchedAt: now)
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 900).rounded(.down) * 900)
        f.minutely = (0..<8).map { PrecipitationSlot(time: start.addingTimeInterval(Double($0) * 900), precipitation: 0) }
        return f
    }

    func testTwoNearbyRainReportsUnderADryRadarMeanDrizzle() {
        let now = Date()
        var f = forecast(temperature: 5, humidity: 92)
        var o = Observation(stationName: "3 Netatmo stations", observedAt: now, temperature: 5, distanceKm: 2)
        o.noteDrizzle(station: "Hamilton Airport", km: 26, condition: .rain, observedAt: now)
        f.observation = o
        // One report is enough in air this damp (Milton, 27 Nov, 8:50 pm: only Pearson, 30 km).
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now).current.condition, .drizzle)

        f.observation?.noteDrizzle(station: "Toronto Pearson", km: 30, condition: .rain, observedAt: now)
        f.observation?.noteDrizzle(station: "Toronto Pearson", km: 30, condition: .rain, observedAt: now)
        XCTAssertEqual(f.observation?.nearbyWetStations?.count, 2, "the same station counts once")
        let shown = f.agreeingNowWithNowcast(at: now)
        XCTAssertEqual(shown.current.condition, .drizzle)
        XCTAssertEqual(shown.nowcast(at: now)?.kind, .rain, "Next 2 hours agrees with the card")
        XCTAssertTrue(shown.skySource?.contains("Hamilton Airport") == true)

        // Drier air here: their rain isn't falling here.
        f.current.humidity = 84
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now).current.condition, .overcast)

        // Snow reports don't count (the radar sees snow), nor do old ones.
        var snow = Observation(stationName: "x", observedAt: now, temperature: 0, distanceKm: 2)
        snow.noteDrizzle(station: "A", km: 20, condition: .snow, observedAt: now)
        snow.noteDrizzle(station: "B", km: 20, condition: .rain, observedAt: now.addingTimeInterval(-7200))
        XCTAssertNil(snow.nearbyWetStations)
    }

    func testMostModelsWetNowInDampAirMeansDrizzle() {
        let now = Date()
        var f = forecast(temperature: 6, humidity: 93)
        var h = HourlyForecast(time: now.addingTimeInterval(-900), temperature: 6, condition: .overcast)
        h.modelCount = 6
        h.modelsWet = 4
        f.hourly = [h]
        let shown = f.agreeingNowWithNowcast(at: now)
        XCTAssertEqual(shown.current.condition, .drizzle)
        XCTAssertEqual(shown.nowcast(at: now)?.kind, .rain, "Next 2 hours agrees with the card")

        // Only a third of them wet, or drier air, or near freezing: left alone.
        f.hourly[0].modelsWet = 2
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now), f)
        f.hourly[0].modelsWet = 4
        f.current.humidity = 85
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now), f)
        f.current.humidity = 93
        f.current.temperature = 0.5
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now), f)
        // A radar showing rain is handled by the radar, not this.
        f.current.temperature = 6
        f.radar = RadarNow(rainMmPerHour: 1, snowCmPerHour: 0, time: now)
        XCTAssertEqual(f.drizzlingRadarCantSee(slots: []), f)
    }

    func testLightEchoCountsInSaturatedAir() {
        let now = Date()
        let light = RadarNow(rainMmPerHour: 0.3, snowCmPerHour: 0, time: now)
        // Damp air: a 0.3 mm/h echo is drizzle reaching the ground.
        let damp = forecast(temperature: 6, humidity: 95).applyingRadar(light)
        XCTAssertEqual(damp.current.condition, .drizzle)
        XCTAssertEqual(damp.nowcast(at: now)?.kind, .rain)
        // Drier air: the same echo is treated as virga or clutter, as before.
        let dry = forecast(temperature: 6, humidity: 80).applyingRadar(light)
        XCTAssertEqual(dry.current.condition, .overcast)
        XCTAssertNil(dry.radar)
    }

    func testMETARNotesRainAtOtherAirports() throws {
        let json = #"""
        [{"icaoId":"KLGA","name":"New York/La Guardia Arpt, NY, US","lat":40.7794,"lon":-73.8803,"obsTime":1794578460,
          "temp":8.9,"dewp":8.1,"wdir":300,"wspd":12,"visib":"10+","wxString":"BR","cover":"OVC"},
         {"icaoId":"KJFK","name":"New York/JF Kennedy Intl, NY, US","lat":40.6392,"lon":-73.7639,"obsTime":1794578460,
          "temp":9.4,"dewp":8.2,"wdir":"VRB","wspd":3,"visib":6,"wxString":"-RA","cover":"OVC"},
         {"icaoId":"KEWR","name":"Newark Liberty Intl, NJ, US","lat":40.6925,"lon":-74.1687,"obsTime":1794578460,
          "temp":9.0,"dewp":8.0,"wdir":200,"wspd":5,"visib":5,"wxString":"-DZ BR","cover":"OVC"}]
        """#
        let nyc = Coordinate(latitude: 40.75, longitude: -73.9)
        let now = Date(timeIntervalSince1970: 1794578460 + 600)
        let o = try XCTUnwrap(METARProvider.parse(Data(json.utf8), near: nyc, now: now, maxDistanceKm: 40, maxAge: 10800))
        XCTAssertEqual(o.stationName, "New York/La Guardia Arpt")
        XCTAssertEqual(o.nearbyWetStations?.count, 2)
        XCTAssertNotNil(o.nearbyDrizzleStation)
    }

    /// 27 Nov, 7:48 pm in Mississauga: Pearson (9 km) said light rain, 92% here, radar dry, drizzling.
    func testNearbyStationRainInSaturatedAirSurvivesADryRadar() {
        let now = Date()
        var f = forecast(temperature: 4, humidity: 92)
        var o = Observation(stationName: "3 Netatmo stations", observedAt: now, temperature: 4, distanceKm: 3)
        o.condition = .rain
        o.conditionText = "Light Rain"
        o.skyStationName = "Toronto Pearson Int'l Airport"
        o.skyDistanceKm = 9
        f.observation = o
        f.current.condition = .rain
        let dryRadar = RadarNow(rainMmPerHour: 0, snowCmPerHour: 0, time: now)
        let shown = f.applyingRadar(dryRadar).agreeingNowWithNowcast(at: now)
        XCTAssertEqual(shown.current.condition, .drizzle)
        XCTAssertTrue(shown.skySource?.contains("Toronto Pearson") == true)
        XCTAssertEqual(shown.nowcast(at: now)?.kind, .rain, "Next 2 hours agrees with the card")

        // Drier air, or a station too far away: the dry radar wins as before.
        var drier = f
        drier.current.humidity = 86
        XCTAssertEqual(drier.applyingRadar(dryRadar).current.condition, .overcast)
        var far = f
        far.observation?.skyDistanceKm = 30
        XCTAssertEqual(far.applyingRadar(dryRadar).current.condition, .overcast)
    }
}
