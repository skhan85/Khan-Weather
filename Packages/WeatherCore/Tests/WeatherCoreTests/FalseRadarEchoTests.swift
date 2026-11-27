import XCTest
@testable import WeatherCore

/// 26 Nov, 9:40 pm in Milton: radar said heavy snow, then moderate rain, with "Rain and snow for at
/// least the next 2 hours", while nothing was falling.
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

    func testEchoOverDryAirIsIgnored() {
        let now = Date()
        let rain = RadarNow(rainMmPerHour: 3, snowCmPerHour: 0, time: now)
        let dry = forecast(temperature: 2, humidity: 73)
        XCTAssertEqual(dry.applyingRadar(rain), dry)
        XCTAssertNil(dry.applyingRadar(rain).observation?.conditionText)

        let humid = forecast(temperature: 2, humidity: 95)
        XCTAssertEqual(humid.applyingRadar(rain).current.condition, .rain)

        // Snow can fall through drier air when it's properly cold.
        let cold = forecast(temperature: -8, humidity: 75)
        XCTAssertEqual(cold.applyingRadar(RadarNow(rainMmPerHour: 0, snowCmPerHour: 0.6, time: now)).current.condition, .snow)
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

        // Wet radar, but over air too dry for it to reach the ground.
        let dryAir = forecast(temperature: 2, humidity: 73)
        XCTAssertNil(dryAir.applyingRadarNowcast(Self.relay(4, from: dryAir.minutely[0].time),
                                                 radarNow: RadarNow(rainMmPerHour: 3, snowCmPerHour: 0, time: now)).nowcast(at: now))
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
}
