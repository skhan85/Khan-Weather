import XCTest
@testable import WeatherCore

final class RadarProviderTests: XCTestCase {
    /// Real response from geo.weather.gc.ca for Milton, 2026-11-13 12:42Z (dry).
    static let dry = """
    {"type":"FeatureCollection","layer":"RADAR_1KM_RRAI","features":[{"type":"Feature","id":"RADAR_1KM_RRAI(-79.884875,43.50711)","geometry":{"type":"Point","coordinates":[-79.8849,43.5071]},"properties":{"value":0,"class":"Undetected","title_en":"Radar precipitation rate for rain [mm/h]","title_fr":"Taux de précipitation radar pour la pluie [mm/h]","time":"2026-11-13T12:42:00Z","dim_reference_time":"N/A"}}]}
    """.data(using: .utf8)!

    func testParsesFeatureInfo() throws {
        let r = try XCTUnwrap(ECCCRadarProvider.parse(Self.dry))
        XCTAssertEqual(r.value, 0)
        XCTAssertEqual(r.time, EnvironmentCanadaProvider.parseDate("2026-11-13T12:42:00Z"))
        XCTAssertNil(try ECCCRadarProvider.parse(#"{"type":"FeatureCollection","features":[]}"#.data(using: .utf8)!))
    }

    func testURLUsesLatLonBoxAndMiddlePixel() {
        let url = ECCCRadarProvider.url(layer: "RADAR_1KM_RSNO", at: Coordinate(latitude: 43.513, longitude: -79.882))
            .absoluteString
        XCTAssertTrue(url.contains("bbox=43.5030,-79.8920,43.5230,-79.8720"))
        XCTAssertTrue(url.contains("query_layers=RADAR_1KM_RSNO"))
        XCTAssertTrue(url.contains("i=1") && url.contains("j=1"))
    }

    func testRadarOverridesCloudyNow() {
        let now = Date()
        let current = CurrentConditions(time: now, temperature: 0, feelsLike: -3, feelsLikeKind: .windChill,
                                        condition: .overcast, isDay: true)
        var f = Forecast(location: Coordinate(latitude: 43.5, longitude: -79.9), timeZoneIdentifier: "America/Toronto",
                         current: current, hourly: [], daily: [], source: "t", fetchedAt: now,
                         observation: Observation(stationName: "CR-27", observedAt: now, temperature: 0))
        f.observation?.conditionText = "Mostly Cloudy"

        let snowing = f.applyingRadar(RadarNow(rainMmPerHour: 0, snowCmPerHour: 0.3, time: now))
        XCTAssertEqual(snowing.current.condition, .snow)
        XCTAssertEqual(snowing.observation?.conditionText, "Light snow")
        XCTAssertNotNil(snowing.radar)

        let dry = f.applyingRadar(RadarNow(rainMmPerHour: 0, snowCmPerHour: 0, time: now))
        XCTAssertEqual(dry, f, "a dry radar leaves the station's sky alone")
        XCTAssertEqual(RadarNow(rainMmPerHour: 3, snowCmPerHour: 0, time: now).description, "Moderate rain")
    }

    /// North Plains, Oregon at 11°C: the mosaic's snow layer lit up, but it was raining.
    func testWarmSnowEchoBecomesRain() {
        let now = Date()
        let current = CurrentConditions(time: now, temperature: 11, feelsLike: 11, feelsLikeKind: .apparent,
                                        condition: .overcast, isDay: true)
        let f = Forecast(location: Coordinate(latitude: 45.6, longitude: -123.0), timeZoneIdentifier: "America/Los_Angeles",
                         current: current, hourly: [], daily: [], source: "t", fetchedAt: now,
                         observation: Observation(stationName: "Portland-Hillsboro Airport", observedAt: now, temperature: 11))
        let wet = f.applyingRadar(RadarNow(rainMmPerHour: 0, snowCmPerHour: 0.7, time: now))
        XCTAssertEqual(wet.current.condition, .rain)
        XCTAssertEqual(wet.observation?.conditionText, "Light rain")

        let cold = RadarNow(rainMmPerHour: 1, snowCmPerHour: 0, time: now).typed(byTemperature: -2)
        XCTAssertEqual(cold.condition, .snow)
        let both = RadarNow(rainMmPerHour: 1, snowCmPerHour: 0.5, time: now)
        XCTAssertEqual(both.typed(byTemperature: 0).condition, .snow)
        XCTAssertEqual(both.typed(byTemperature: 2).condition, .rain)
    }
}
