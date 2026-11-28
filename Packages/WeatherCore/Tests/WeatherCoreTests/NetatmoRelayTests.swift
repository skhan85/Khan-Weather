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

    func testTwoNearbyStationsAreMadeUpToThreeFromFurtherOut() throws {
        let json = #"""
        {"stations":[
          {"lat":43.513,"lon":-79.86,"city":"Milton","temperature":5.0,"observed":1794580700},
          {"lat":43.513,"lon":-79.85,"city":"Milton","temperature":6.0,"observed":1794580700},
          {"lat":43.513,"lon":-79.80,"city":"Milton","temperature":5.2,"observed":1794580700},
          {"lat":43.513,"lon":-79.70,"city":"Mississauga","temperature":9.0,"observed":1794580700}
        ]}
        """#
        let o = try XCTUnwrap(NetatmoRelayProvider.parse(Data(json.utf8), near: milton, now: now, radiusKm: 5, maxAge: 3600))
        // 1.8 km and 2.6 km inside the radius, 6.6 km makes three; 14.6 km is too far. Middle of 5.0, 5.2, 6.0.
        XCTAssertEqual(o.temperature, 5.2)
        XCTAssertEqual(o.stationName, "3 Netatmo stations in Milton")
    }

    func testOnlyFarStationsCountForNothing() throws {
        let json = #"{"stations":[{"lat":43.513,"lon":-79.80,"temperature":5.2,"observed":1794580700}]}"#
        XCTAssertNil(try NetatmoRelayProvider.parse(Data(json.utf8), near: milton, now: now, radiusKm: 5, maxAge: 3600))
    }

    func testSmoothingAveragesARecentCloseReading() {
        var before = Observation(stationName: "2 Netatmo stations", observedAt: now, temperature: 5.4)
        before.dataProvider = "NETATMO"
        var after = Observation(stationName: "2 Netatmo stations", observedAt: now.addingTimeInterval(1200), temperature: 5.8)
        after.dataProvider = "NETATMO"
        XCTAssertEqual(after.smoothed(after: before, now: now.addingTimeInterval(1260)).temperature, 5.6)
        // A big change is real and comes straight through, and so does anything after a long gap.
        var jump = after
        jump.temperature = 8
        XCTAssertEqual(jump.smoothed(after: before, now: now.addingTimeInterval(1260)).temperature, 8)
        XCTAssertEqual(after.smoothed(after: before, now: now.addingTimeInterval(3600)).temperature, 5.8)
        XCTAssertEqual(after.smoothed(after: nil).temperature, 5.8)
    }

    func testPlainSourceWords() {
        var home = Observation(stationName: "3 Netatmo stations in Milton", observedAt: now, temperature: 2, distanceKm: 2.9)
        home.dataProvider = "NETATMO"
        XCTAssertEqual(WeatherFormat.readingSource(home), "3 home weather stations about 3 km away")
        let official = Observation(stationName: "Toronto Pearson", observedAt: now, temperature: 2, distanceKm: 25.2)
        XCTAssertEqual(WeatherFormat.readingSource(official), "Toronto Pearson, about 25 km away")
        XCTAssertEqual(WeatherFormat.plainStationName("CR-27 Campbellville"), "Campbellville")
        XCTAssertEqual(WeatherFormat.plainStationName("Burlington Lift Bridge"), "Burlington Lift Bridge")
        XCTAssertEqual(WeatherFormat.feelsLikeLabel(.windChill), "Feels like")
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

    func testSunnyStationsAreDroppedButShadedOnesKeptNextToAnOfficialStation() {
        // 15 Nov, 4:09 pm: Campbellville 6°, nearest home stations 7.1, 9.4, 9.9, 9.5, 16.4°.
        let official = Observation(stationName: "CR-27 Campbellville", observedAt: now, temperature: 6, distanceKm: 8)
        var local = Observation(stationName: "3 Netatmo stations in Milton", observedAt: now, temperature: 9.4, distanceKm: 0.24)
        local.dataProvider = "NETATMO"
        local.stationTemperatures = [7.1, 16.4, 9.4, 9.9, 9.5]
        let merged = HyperlocalObservationProvider.merge(official: official, netatmo: local)
        XCTAssertEqual(merged.dataProvider, "NETATMO")
        XCTAssertEqual(merged.temperature, 7.1)
        XCTAssertEqual(merged.stationName, "Netatmo station in Milton")
        local.stationTemperatures = [16.4, 9.9]
        XCTAssertEqual(HyperlocalObservationProvider.merge(official: official, netatmo: local).stationName, "CR-27 Campbellville")
    }

    func testDryGaugesNextDoorOverruleDistantRain() throws {
        // Nov 14, 12:18: "Light Rain" from Pearson, 25 km away, while it was dry in Milton.
        let json = #"""
        {"stations":[
          {"lat":43.5142,"lon":-79.8845,"city":"Milton","temperature":7.1,"observed":1794580705,"rain_60min":0},
          {"lat":43.52,"lon":-79.84,"city":"Milton","temperature":6.9,"observed":1794580600}
        ]}
        """#
        let local = try XCTUnwrap(NetatmoRelayProvider.parse(Data(json.utf8), near: milton, now: now, radiusKm: 5, maxAge: 3600))
        XCTAssertEqual(local.rainGauges, 1)
        XCTAssertTrue(local.gaugesSayDry)
        let pearson = Observation(stationName: "Toronto Pearson", observedAt: now, temperature: 6, condition: .rain,
                                  conditionText: "Light Rain", distanceKm: 25)
        let merged = HyperlocalObservationProvider.merge(official: pearson, netatmo: local)
        let forecast = Forecast(location: milton, timeZoneIdentifier: "America/Toronto",
                                current: CurrentConditions(time: now, temperature: 5, feelsLike: 2, feelsLikeKind: .apparent,
                                                           condition: .rain, isDay: true),
                                hourly: [], daily: [], source: "t", fetchedAt: now)
        let shown = forecast.applying(merged)
        XCTAssertEqual(shown.current.condition, .overcast)
        XCTAssertNil(shown.observation?.conditionText)
        // A faint radar echo doesn't bring the rain back; a real downpour would.
        XCTAssertEqual(shown.applyingRadar(RadarNow(rainMmPerHour: 0.3, snowCmPerHour: 0, time: now)).current.condition, .overcast)
        XCTAssertEqual(shown.applyingRadar(RadarNow(rainMmPerHour: 4, snowCmPerHour: 0, time: now)).current.condition, .rain)
    }

    func testWetGaugeKeepsRain() throws {
        let json = #"{"stations":[{"lat":43.5142,"lon":-79.8845,"temperature":7,"observed":1794580705,"rain_60min":0.4}]}"#
        let local = try XCTUnwrap(NetatmoRelayProvider.parse(Data(json.utf8), near: milton, now: now, radiusKm: 5, maxAge: 3600))
        XCTAssertFalse(local.gaugesSayDry)
    }

    func testDryRadarOverhearsDistantRain() {
        // No rain gauges nearby: the radar over Milton decides.
        let local = Observation(stationName: "2 Netatmo stations in Milton", observedAt: now, temperature: 7, distanceKm: 2.9)
        let pearson = Observation(stationName: "Toronto Pearson", observedAt: now, temperature: 6, condition: .rain,
                                  conditionText: "Light Rain", distanceKm: 25)
        let merged = HyperlocalObservationProvider.merge(official: pearson, netatmo: local)
        XCTAssertFalse(merged.skyIsLocal)
        let forecast = Forecast(location: milton, timeZoneIdentifier: "America/Toronto",
                                current: CurrentConditions(time: now, temperature: 5, feelsLike: 2, feelsLikeKind: .apparent,
                                                           condition: .rain, isDay: true),
                                hourly: [], daily: [], source: "t", fetchedAt: now).applying(merged)
        XCTAssertEqual(forecast.current.condition, .rain, "without radar, the distant sky stands")
        let dry = forecast.applyingRadar(RadarNow(rainMmPerHour: 0, snowCmPerHour: 0, time: now))
        XCTAssertEqual(dry.current.condition, .overcast)
        XCTAssertNil(dry.observation?.conditionText)
    }

    /// A tight warm cluster 4° above a road-weather station: the models break the tie.
    func testModelsBreakTieBetweenWarmClusterAndRoadStation() {
        var road = Observation(stationName: "CR-27 Campbellville", observedAt: now, temperature: 1, distanceKm: 8)
        road.dataProvider = "ON-MTO"
        var cluster = Observation(stationName: "3 Netatmo stations in Milton", observedAt: now, temperature: 5, distanceKm: 0.5)
        cluster.dataProvider = "NETATMO"
        cluster.stationTemperatures = [4.8, 5.0, 5.3]
        let merged = HyperlocalObservationProvider.merge(official: road, netatmo: cluster)
        XCTAssertEqual(merged.temperature, 5, "a tight cluster may stand 4° from the road station")
        XCTAssertEqual(merged.officialTemperature, 1)

        func forecast(modelsLow: Double, modelsHigh: Double) -> Forecast {
            var h0 = HourlyForecast(time: now.addingTimeInterval(-1800), temperature: 3, condition: .clear, isDay: false)
            var h1 = HourlyForecast(time: now.addingTimeInterval(1800), temperature: 3, condition: .clear, isDay: false)
            h0.modelLow = modelsLow; h0.modelHigh = modelsHigh
            h1.modelLow = modelsLow; h1.modelHigh = modelsHigh
            return Forecast(location: milton, timeZoneIdentifier: "America/Toronto",
                            current: CurrentConditions(time: now, temperature: 3, feelsLike: 3, feelsLikeKind: .apparent,
                                                       condition: .clear, isDay: false),
                            hourly: [h0, h1], daily: [], source: "t", fetchedAt: now)
        }
        // Models 0.5-2.5° (middle 1.5): closer to the road station, which wins.
        let cold = forecast(modelsLow: 0.5, modelsHigh: 2.5).applying(merged)
        XCTAssertEqual(cold.current.temperature, 1)
        XCTAssertEqual(cold.observation?.stationName, "CR-27 Campbellville")
        // Models 3.5-5.5° (middle 4.5): the home stations win.
        let mild = forecast(modelsLow: 3.5, modelsHigh: 5.5).applying(merged)
        XCTAssertEqual(mild.current.temperature, 5)
        XCTAssertEqual(mild.observation?.dataProvider, "NETATMO")
    }
}
