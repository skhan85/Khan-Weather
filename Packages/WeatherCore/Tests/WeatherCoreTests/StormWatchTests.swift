import XCTest
@testable import WeatherCore

final class StormWatchTests: XCTestCase {
    let milton = Coordinate(latitude: 43.5183, longitude: -79.8774)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let toronto = TimeZone(identifier: "America/Toronto")!

    /// Storms steered from the west at 40 km/h, in unstable summer air.
    var summer: StormContext {
        StormContext(steeringSpeed: 40, steeringFrom: 270, cape: 1200, thunderAt: nil, maxChance: 60, temperature: 26)
    }

    private func samples(heavyAt along: Double? = nil, across: Double = 0, rain: Double = 25, snow: Double = 0) -> [StormSample] {
        var list: [StormSample] = []
        for a in StormWatch.along {
            for x in StormWatch.across {
                let hit = a == along && x == across
                list.append(StormSample(alongKm: a, acrossKm: x, coordinate: milton,
                                        rain: hit ? rain : 0.5, snow: hit ? snow : 0))
            }
        }
        return list
    }

    func testScanCorridorPointsUpwind() throws {
        let points = try XCTUnwrap(StormWatch.scanPoints(around: milton, context: summer))
        XCTAssertEqual(points.count, StormWatch.along.count * StormWatch.across.count)
        // From the west: every point lies west of Milton, within about 6 km north or south of it.
        for p in points {
            XCTAssertLessThan(p.coordinate.longitude, milton.longitude)
            XCTAssertEqual(EnvironmentCanadaProvider.distanceKm(milton, Coordinate(latitude: milton.latitude, longitude: p.coordinate.longitude)),
                           p.alongKm, accuracy: 0.5)
            XCTAssertLessThan(abs(p.coordinate.latitude - milton.latitude) * 111, 6.5)
        }
        XCTAssertNil(StormWatch.scanPoints(around: milton, context: StormContext(cape: 1000)), "no steering wind, no corridor")
    }

    func testThunderstormUpwindGivesArrivalTime() throws {
        let storm = try XCTUnwrap(StormWatch.assess(samples: samples(heavyAt: 26), overhead: nil, context: summer, now: now))
        XCTAssertEqual(storm.kind, .thunderstorm)
        XCTAssertEqual(storm.source, .radar)
        XCTAssertEqual(storm.arrival.timeIntervalSince(now), 26.0 / 40 * 3600, accuracy: 1)
        XCTAssertEqual(storm.title, "Thunderstorm heading your way")
        let body = storm.body(at: now, timeZone: toronto)
        XCTAssertTrue(body.hasPrefix("A thunderstorm about 25 km west of you, moving east at 40 km/h. Likely here around"), body)
    }

    func testNearestEchoWins() throws {
        var list = samples(heavyAt: 52)
        list[3] = StormSample(alongKm: 16, acrossKm: -6, coordinate: milton, rain: 12, snow: 0)
        let storm = try XCTUnwrap(StormWatch.assess(samples: list, overhead: nil, context: summer, now: now))
        XCTAssertEqual(storm.distanceKm, 16)
    }

    func testStableAirDownpourIsHeavyRain() throws {
        var autumn = summer
        autumn.cape = 20
        autumn.temperature = 9
        let storm = try XCTUnwrap(StormWatch.assess(samples: samples(heavyAt: 16, rain: 14), overhead: nil, context: autumn, now: now))
        XCTAssertEqual(storm.kind, .heavyRain)
        XCTAssertEqual(storm.title, "Heavy rain heading your way")
    }

    func testSnowSquall() throws {
        let winter = StormContext(steeringSpeed: 50, steeringFrom: 300, cape: 50, maxChance: 80, temperature: -6)
        let storm = try XCTUnwrap(StormWatch.assess(samples: samples(heavyAt: 38, rain: 0, snow: 3), overhead: nil, context: winter, now: now))
        XCTAssertEqual(storm.kind, .snowSquall)
        XCTAssertTrue(storm.body(at: now, timeZone: toronto).contains("north-west of you, moving south-east at 50 km/h"))
    }

    func testOrdinaryRainAndFarStormsStayQuiet() {
        // Light rain only.
        XCTAssertNil(StormWatch.assess(samples: samples(), overhead: nil, context: summer, now: now))
        // A storm 52 km off, crawling at 15 km/h: over three hours away.
        var slow = summer
        slow.steeringSpeed = 10
        XCTAssertNil(StormWatch.assess(samples: samples(heavyAt: 52), overhead: nil, context: slow, now: now))
    }

    func testAlreadyPouringHereIsNotOnTheWay() {
        let overhead = RadarNow(rainMmPerHour: 30, snowCmPerHour: 0, time: now)
        XCTAssertNil(StormWatch.assess(samples: samples(heavyAt: 8), overhead: overhead, context: summer, now: now))
    }

    func testForecastOnlyThunderWithoutRadar() throws {
        var ctx = summer
        ctx.thunderAt = now.addingTimeInterval(3600)
        let storm = try XCTUnwrap(StormWatch.assess(samples: [], overhead: nil, context: ctx, now: now))
        XCTAssertEqual(storm.source, .forecast)
        XCTAssertEqual(storm.title, "Thunderstorms possible")
        // Radar read and clear upwind: trust the radar.
        XCTAssertNil(StormWatch.assess(samples: samples(), overhead: nil, context: ctx, now: now))
        // Thunder code in stable air: likely a model artefact.
        ctx.cape = 50
        XCTAssertNil(StormWatch.assess(samples: [], overhead: nil, context: ctx, now: now))
    }

    func testQuietPeriod() {
        let storm = StormHeadsUp(kind: .heavyRain, source: .radar, arrival: now)
        XCTAssertNil(StormWatch.shouldNotify(storm, lastNotified: now.addingTimeInterval(-3600), now: now))
        XCTAssertNotNil(StormWatch.shouldNotify(storm, lastNotified: now.addingTimeInterval(-4 * 3600), now: now))
    }

    func testCompassWords() {
        XCTAssertEqual(StormWatch.compassWord(270), "west")
        XCTAssertEqual(StormWatch.compassWord(450), "east")
        XCTAssertEqual(StormWatch.compassWord(-45), "north-west")
    }

    func testParsesOpenMeteoContext() throws {
        let t0 = now.timeIntervalSince1970 - 600   // the current hour started 10 min ago
        let json = """
        {"hourly":{"time":[\(t0 - 3600),\(t0),\(t0 + 3600),\(t0 + 7200),\(t0 + 10800)],
        "temperature_2m":[25,26,27,27,26],
        "precipitation_probability":[10,20,55,70,40],
        "weather_code":[2,3,80,95,95],
        "cape":[400,800,1500,1700,1200],
        "wind_speed_700hPa":[30,40,40,40,40],
        "wind_direction_700hPa":[200,350,10,null,0]}}
        """.data(using: .utf8)!
        let c = try StormWatchProvider.parse(json, now: now)
        XCTAssertEqual(c.temperature, 26)
        XCTAssertEqual(c.maxChance, 70)
        XCTAssertEqual(c.cape, 1700)
        XCTAssertEqual(c.thunderAt?.timeIntervalSince1970, t0 + 7200)
        // 350° and 10° average to north, not south.
        let from = try XCTUnwrap(c.steeringFrom)
        XCTAssertTrue(from < 5 || from > 355, "\(from)")
        XCTAssertEqual(try XCTUnwrap(c.steeringSpeed), 40, accuracy: 1)
        XCTAssertTrue(c.worthScanning)
    }
}
