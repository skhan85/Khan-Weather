import XCTest
@testable import WeatherCore

/// 26 Nov, 9:40 pm in Milton: radar said "Heavy snow" at 0° while it was raining (Pearson and Hamilton
/// reported rain at 1-2°, Hamilton's gauge 4-6 mm an hour). The radar echo was real; the type and the
/// rate were wrong.
final class FalseRadarEchoTests: XCTestCase {
    static let milton = Coordinate(latitude: 43.513, longitude: -79.882)

    static func featureInfo(_ value: Double, time: String = "2026-11-27T02:36:00Z") -> Data {
        Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"value":\#(value),"time":"\#(time)"}}]}"#.utf8)
    }

    /// Answers with `spot` for the requested point itself and `around` for the four neighbours.
    static func loader(spot: Double, around: Double, time: Date = Date()) -> ECCCRadarProvider.DataLoader {
        let stamp = ISO8601DateFormatter().string(from: time)
        let centreBox = ECCCRadarProvider.url(layer: "RADAR_1KM_RRAI", at: milton).query!
            .components(separatedBy: "&").first { $0.hasPrefix("bbox=") }!
        return { request in
            let url = request.url!.absoluteString
            let isCentre = url.contains(centreBox)
            let value = url.contains("RADAR_1KM_RRAI") ? (isCentre ? spot : around) : 0
            return (featureInfo(value, time: stamp),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testMedian() {
        XCTAssertEqual(ECCCRadarProvider.median([3, 0, 0, 0, 0]), 0)
        XCTAssertEqual(ECCCRadarProvider.median([3, 2, 2.5, 0, 4]), 2.5)
        XCTAssertEqual(ECCCRadarProvider.median([1, 3]), 2)
    }

    func testNeighboursAreAboutTwoKilometresAway() {
        let points = ECCCRadarProvider.neighbourhoodPoints(around: Self.milton)
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points[0], Self.milton)
        for p in points.dropFirst() {
            XCTAssertEqual(EnvironmentCanadaProvider.distanceKm(Self.milton, p), 2, accuracy: 0.1)
        }
    }

    func testSingleBrightPixelIsOutvoted() async throws {
        let speck = try await ECCCRadarProvider(loader: Self.loader(spot: 3.2, around: 0)).now(at: Self.milton)
        XCTAssertEqual(speck?.isPrecipitating, false)

        let widespread = try await ECCCRadarProvider(loader: Self.loader(spot: 3.2, around: 2.8)).now(at: Self.milton)
        XCTAssertEqual(widespread?.rainMmPerHour, 2.8)
    }

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

    func testModelsDecideRainOrSnowNearFreezing() {
        let now = Date()
        // 02:42Z frame over Milton: rain layer 3.2 mm/h, snow layer 1.7 cm/h (the same echo read both ways).
        let echo = RadarNow(rainMmPerHour: 3.2, snowCmPerHour: 1.7, time: now)

        var f = forecast(temperature: 0, humidity: 87)
        f.hourly = [HourlyForecast(time: now.addingTimeInterval(-600), temperature: 1.5, condition: .rain)]
        f.hourly[0].rain = 1.2
        f.hourly[0].snowfall = 0
        let shown = f.applyingRadar(echo)
        XCTAssertEqual(shown.current.condition, .rain)
        XCTAssertEqual(shown.observation?.conditionText ?? shown.radar?.description, "Moderate rain")

        // Models calling snow: snow, at the snow layer's rate, so moderate rather than heavy.
        f.hourly[0].rain = 0
        f.hourly[0].snowfall = 1.0
        XCTAssertEqual(f.applyingRadar(echo).current.condition, .snow)
        XCTAssertEqual(f.applyingRadar(echo).radar?.snowCmPerHour, 1.7)
        XCTAssertEqual(echo.typed(byTemperature: 0, models: .snow).description, "Heavy snow")
        XCTAssertEqual(RadarNow(rainMmPerHour: 1.2, snowCmPerHour: 0.7, time: now).typed(byTemperature: 0, models: .snow).description,
                       "Moderate snow")

        // No model wet: the old temperature rule.
        XCTAssertEqual(echo.typed(byTemperature: 0).condition, .snow)
        XCTAssertEqual(echo.typed(byTemperature: 2).condition, .rain)
        // Models never overrule clearly warm or cold air.
        XCTAssertEqual(echo.typed(byTemperature: -3, models: .rain).condition, .snow)
        XCTAssertEqual(echo.typed(byTemperature: 4, models: .snow).condition, .rain)
    }

    func testChartIntensityMatchesBands() {
        let now = Date()
        // 3.2 mm/h of rain (0.8 mm a slot) is moderate: between the lines, not at "Heavy".
        let moderate = PrecipitationSlot(time: now, precipitation: 0.8, rain: 0.8).intensity
        XCTAssertGreaterThan(moderate, 1.0 / 3)
        XCTAssertLessThan(moderate, 2.0 / 3)
        XCTAssertEqual(PrecipitationSlot(time: now, precipitation: 4, rain: 4).intensity, 1)
        XCTAssertGreaterThanOrEqual(PrecipitationSlot(time: now, precipitation: 0.3, snowfall: 0.3).intensity, 2.0 / 3)
        XCTAssertEqual(PrecipitationSlot(time: now, precipitation: 0).intensity, 0)
    }

    /// 26 Nov, 11 pm: rain at 1° with a trace of model snow said "Rain and snow for at least the next 2 hours".
    func testTraceOfSnowInRainIsStillRain() {
        let now = Date()
        XCTAssertEqual(PrecipitationSlot(time: now, precipitation: 0.8, rain: 0.8, snowfall: 0.05).kind, .rain)
        XCTAssertEqual(PrecipitationSlot(time: now, precipitation: 0.5, rain: 0.2, snowfall: 0.4).kind, .mixed)
        XCTAssertEqual(PrecipitationSlot(time: now, precipitation: 0.3, snowfall: 0.4).kind, .snow)
        let slots = (0..<8).map {
            PrecipitationSlot(time: now.addingTimeInterval(Double($0) * 900), precipitation: 0.6, rain: 0.6, snowfall: 0.02)
        }
        XCTAssertEqual(Nowcast.kind(of: slots), .rain)
    }

    /// 26 Nov, 11:03 pm: hourly said rain at 1°, Next 2 hours said "Rain and snow" with purple bars.
    func testNextTwoHoursFollowsTheHourlyRainOrSnow() {
        let now = Date()
        var f = forecast(temperature: 1, humidity: 85)
        f.hourly = [HourlyForecast(time: f.minutely[0].time, temperature: 1, condition: .rain),
                    HourlyForecast(time: f.minutely[0].time.addingTimeInterval(3600), temperature: 1, condition: .rain),
                    HourlyForecast(time: f.minutely[0].time.addingTimeInterval(7200), temperature: 1, condition: .rain)]
        for i in f.hourly.indices { f.hourly[i].rain = 2; f.hourly[i].snowfall = 0 }
        f.minutely = f.minutely.map { PrecipitationSlot(time: $0.time, precipitation: 0.5, rain: 0.3, snowfall: 0.3) }
        let slots = f.nowcastSlots(at: now)
        XCTAssertTrue(slots.allSatisfy { $0.kind == .rain && $0.snowfall == 0 })
        XCTAssertEqual(f.nowcast(at: now)?.kind, .rain)
    }

    /// 27 Nov, 3:06 am: "Light Rain" from Campbellville (8 km) on the Now card, "Rain starting in about
    /// 55 min" under it, with the radar over Milton dry.
    func testNowCardAndNextTwoHoursAgree() {
        let now = Date()
        var f = forecast(temperature: 2, humidity: 86)
        var o = Observation(stationName: "3 Netatmo stations in Milton", observedAt: now, temperature: 2, distanceKm: 3)
        o.condition = .rain
        o.conditionText = "Light Rain"
        o.skyStationName = "CR-27 Campbellville"
        o.skyDistanceKm = 8
        f.observation = o
        f.current.condition = .rain
        f.minutely[4] = PrecipitationSlot(time: f.minutely[4].time, precipitation: 0.3, rain: 0.3)

        // The radar over the spot is dry: it wins over the station 8 km away.
        let dry = f.applyingRadar(RadarNow(rainMmPerHour: 0, snowCmPerHour: 0, time: now))
        XCTAssertEqual(dry.current.condition, .overcast)
        XCTAssertNil(dry.observation?.conditionText)
        if case .starting = dry.nowcast(at: now)?.change {} else { XCTFail("rain is still coming later") }

        // Without radar the station's rain stands, and Next 2 hours says it's raining now.
        let n = f.nowcast(at: now)
        XCTAssertEqual(n?.kind, .rain)
        if case .starting = n?.change { XCTFail("the card says rain now; the line mustn't say it starts later") }

        // Drizzle from that station stays: the radar often misses it.
        var drizzle = f
        drizzle.current.condition = .drizzle
        XCTAssertEqual(drizzle.applyingRadar(RadarNow(rainMmPerHour: 0, snowCmPerHour: 0, time: now)).current.condition, .drizzle)
    }

    /// 27 Nov, 8:54 am: "Overcast" on the card under "Rain for at least the next 2 hours" while it drizzled.
    func testCardFollowsWetNextTwoHours() {
        let now = Date()
        var f = forecast(temperature: 3, humidity: 89)
        f.minutely = f.minutely.map { PrecipitationSlot(time: $0.time, precipitation: 0.1, rain: 0.1) }
        let shown = f.agreeingNowWithNowcast(at: now)
        XCTAssertEqual(shown.current.condition, .drizzle)
        XCTAssertEqual(f.nowcast(at: now)?.change, .continuing)

        f.minutely = f.minutely.map { PrecipitationSlot(time: $0.time, precipitation: 0.4, rain: 0.4) }
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now).current.condition, .rain)

        // Dry Next 2 hours: the card is left alone.
        f.minutely = f.minutely.map { PrecipitationSlot(time: $0.time, precipitation: 0) }
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now), f)
    }

    static func relay(_ rate: Double, from start: Date) -> RelayNowcast {
        let slots = (0..<20).map { i -> String in
            let t = start.timeIntervalSince1970 + Double(i) * 360
            return #"{"time":"","epoch":\#(t),"precip_mmh":\#(rate),"rain_mmh":0,"snow_cmh":\#(rate)}"#
        }
        return try! JSONDecoder().decode(RelayNowcast.self,
                                         from: Data(#"{"slots":[\#(slots.joined(separator: ","))]}"#.utf8))
    }

    func testRelayIgnoredWhenCheckedRadarIsDry() {
        let f = forecast(temperature: 0, humidity: 87)
        let now = Date()
        let relay = Self.relay(4, from: f.minutely[0].time)
        let dryRadar = RadarNow(rainMmPerHour: 0, snowCmPerHour: 0, time: now)
        XCTAssertNil(f.applyingRadarNowcast(relay, radarNow: dryRadar).nowcast(at: now))

        // Without a checked reading the relay still counts, as before.
        XCTAssertNotNil(f.applyingRadarNowcast(relay).nowcast(at: now))

        // With the radar agreeing that snow is falling, it counts too.
        let snowing = RadarNow(rainMmPerHour: 0, snowCmPerHour: 1.2, time: now)
        XCTAssertNotNil(f.applyingRadarNowcast(relay, radarNow: snowing).nowcast(at: now))

    }

    // MARK: Home stations on the first load

    static func netatmo(observedAgo: TimeInterval) -> Data {
        let t = Date().timeIntervalSince1970 - observedAgo
        return Data(#"""
        {"stations":[
          {"lat":43.52,"lon":-79.87,"city":"Milton","temperature":2.1,"observed":\#(t)},
          {"lat":43.50,"lon":-79.89,"city":"Milton","temperature":2.3,"observed":\#(t)},
          {"lat":43.53,"lon":-79.88,"city":"Milton","temperature":1.9,"observed":\#(t)}
        ]}
        """#.utf8)
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testStaleRelayAnswerIsRetriedOnce() async throws {
        let calls = Calls()
        let provider = NetatmoRelayProvider(loader: { request in
            let first = calls.next() == 1
            return (Self.netatmo(observedAgo: first ? 2 * 3600 : 300),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let o = try await provider.observation(near: Self.milton)
        XCTAssertEqual(o?.dataProvider, "NETATMO")
        XCTAssertEqual(o?.temperature, 2.1)
        XCTAssertEqual(calls.count, 2)
    }

    func testRelayErrorIsRetriedOnce() async throws {
        let calls = Calls()
        let provider = NetatmoRelayProvider(loader: { request in
            let status = calls.next() == 1 ? 502 : 200
            return (Self.netatmo(observedAgo: 300),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let o = try await provider.observation(near: Self.milton)
        XCTAssertEqual(o?.dataProvider, "NETATMO")
        XCTAssertEqual(calls.count, 2)
    }

    func testNoStationsNearbyIsNotRetried() async throws {
        let calls = Calls()
        let provider = NetatmoRelayProvider(loader: { request in
            _ = calls.next()
            return (Data(#"{"stations":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let o = try await provider.observation(near: Self.milton)
        XCTAssertNil(o)
        XCTAssertEqual(calls.count, 1)
    }

    /// 27 Nov, 10:36 am in Milton: drizzling, radar dry, card "Overcast", rain "starting in about 40 min".
    func testDrizzleTheRadarCantSee() {
        let now = Date()
        var f = forecast(temperature: 3, humidity: 92)
        f.minutely = f.minutely.enumerated().map { i, s in
            PrecipitationSlot(time: s.time, precipitation: i >= 3 ? 0.3 : 0, rain: i >= 3 ? 0.3 : 0)
        }
        let shown = f.agreeingNowWithNowcast(at: now)
        XCTAssertEqual(shown.current.condition, .drizzle)
        XCTAssertEqual(shown.observation?.conditionText ?? shown.current.condition.description, "Drizzle")
        // Next 2 hours agrees: wet from now on, not "stopping in 15 min" then "starting in 45".
        XCTAssertEqual(shown.nowcast(at: now)?.change, .continuing)

        // Drier air, or rain more than an hour off: left alone.
        var dry = forecast(temperature: 3, humidity: 84)
        dry.minutely = f.minutely
        XCTAssertEqual(dry.agreeingNowWithNowcast(at: now), dry)
        var later = f
        later.minutely = f.minutely.enumerated().map { i, s in
            PrecipitationSlot(time: s.time, precipitation: i >= 6 ? 0.3 : 0, rain: i >= 6 ? 0.3 : 0)
        }
        XCTAssertEqual(later.agreeingNowWithNowcast(at: now), later)
    }

    func testDistantDrizzleReportNeedsDampAir() {
        let now = Date()
        var f = forecast(temperature: 3, humidity: 89)
        var o = Observation(stationName: "Milton", observedAt: now, temperature: 3, distanceKm: 3)
        o.noteDrizzle(station: "Hamilton Airport", km: 26, condition: .drizzle, observedAt: now)
        f.observation = o
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now).current.condition, .drizzle)

        // Same report, drier air here: not enough on its own.
        f.current.humidity = 80
        XCTAssertEqual(f.agreeingNowWithNowcast(at: now).current.condition, .overcast)

        // Too far away to count at all.
        var far = Observation(stationName: "Milton", observedAt: now, temperature: 3, distanceKm: 3)
        far.noteDrizzle(station: "Kitchener Airport", km: 55, condition: .drizzle, observedAt: now)
        XCTAssertNil(far.nearbyDrizzleStation)
    }

    func testDryRadarKeepsDrizzleInDampAir() {
        let now = Date()
        var f = forecast(temperature: 4, humidity: 93)
        f.current.condition = .drizzle
        let dryRadar = RadarNow(rainMmPerHour: 0, snowCmPerHour: 0, time: now)
        XCTAssertEqual(f.applyingRadar(dryRadar).current.condition, .drizzle)
        f.current.humidity = 70
        XCTAssertEqual(f.applyingRadar(dryRadar).current.condition, .overcast)
    }
}
