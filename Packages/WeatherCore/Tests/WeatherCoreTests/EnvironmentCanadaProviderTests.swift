import XCTest
@testable import WeatherCore

final class EnvironmentCanadaProviderTests: XCTestCase {
    /// Shape copied from a real api.weather.gc.ca response (Brampton city page, 2026-11-12 13:00Z),
    /// trimmed to the fields we use. A second, farther city has an older observation.
    static let sample = """
    {
      "type": "FeatureCollection", "numberMatched": 2, "numberReturned": 2,
      "features": [
        {
          "id": "on-4", "type": "Feature",
          "geometry": {"type": "Point", "coordinates": [-79.76, 43.69]},
          "properties": {
            "identifier": "on-4", "name": {"en": "Brampton", "fr": "Brampton"},
            "currentConditions": {
              "iconCode": {"format": "gif", "value": 12},
              "timestamp": {"en": "2026-11-12T13:00:00Z", "fr": "2026-11-12T13:00:00Z"},
              "relativeHumidity": {"units": {"en": "%"}, "qaValue": {"en": 100}, "value": {"en": 85}},
              "wind": {
                "speed": {"unitType": {"en": "metric"}, "units": {"en": "km/h"}, "value": {"en": 23}},
                "direction": {"value": {"en": "NE"}},
                "bearing": {"units": {"en": "degrees"}, "value": {"en": 56.0}},
                "gust": {"units": {"en": "km/h"}, "value": {"en": 32}}
              },
              "temperature": {"unitType": {"en": "metric"}, "units": {"en": "C"}, "value": {"en": 4.0}},
              "dewpoint": {"unitType": {"en": "metric"}, "units": {"en": "C"}, "value": {"en": 1.7}},
              "station": {"code": {"en": "yyz"}, "lat": {"en": "43.68N"}, "lon": {"en": "79.63W", "fr": "79.63O"},
                          "value": {"en": "Toronto Pearson Int'l Airport", "fr": "Aéroport int. Pearson de Toronto"}},
              "condition": {"en": "Light Rain", "fr": "Pluie faible"},
              "windChill": {"unitType": {"en": "metric"}, "value": {"en": -3}, "qaValue": {"en": 100}}
            },
            "warnings": []
          }
        },
        {
          "id": "on-143", "type": "Feature",
          "geometry": {"type": "Point", "coordinates": [-79.40, 43.74]},
          "properties": {
            "name": {"en": "Toronto"},
            "currentConditions": {
              "timestamp": {"en": "2026-11-12T06:00:00Z"},
              "temperature": {"value": {"en": 2.0}},
              "station": {"lat": {"en": "43.63N"}, "lon": {"en": "79.40W"}, "value": {"en": "Toronto City Centre"}},
              "condition": {"en": "Cloudy"}
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!

    let now = ISO8601DateFormatter().date(from: "2026-11-12T13:30:00Z")!
    let mississauga = Coordinate(latitude: 43.59, longitude: -79.64)

    func testParsesNearestFreshObservation() throws {
        let o = try XCTUnwrap(EnvironmentCanadaProvider.parse(Self.sample, near: mississauga, now: now,
                                                              maxDistanceKm: 60, maxAge: 3 * 3600))
        XCTAssertEqual(o.stationName, "Toronto Pearson Int'l Airport")
        XCTAssertEqual(o.temperature, 4.0)
        // Computed from 4 °C and 23 km/h, not the page's own −3.
        XCTAssertEqual(try XCTUnwrap(o.feelsLike), -0.55, accuracy: 0.05)
        XCTAssertEqual(o.feelsLikeKind, .windChill)
        XCTAssertEqual(try XCTUnwrap(o.distanceKm), 10, accuracy: 1)
        XCTAssertEqual(o.humidity, 85)
        XCTAssertEqual(o.windSpeed, 23)
        XCTAssertEqual(o.windDirection, 56)
        XCTAssertEqual(o.condition, .rain)
        XCTAssertEqual(o.conditionText, "Light Rain")
    }

    func testIgnoresStaleAndDistantStations() throws {
        // Only the stale Toronto City Centre observation is within 10 km of this point.
        let downtown = Coordinate(latitude: 43.64, longitude: -79.39)
        XCTAssertNil(try EnvironmentCanadaProvider.parse(Self.sample, near: downtown, now: now,
                                                         maxDistanceKm: 10, maxAge: 3 * 3600))
        // Far away: nothing within 60 km.
        let ottawa = Coordinate(latitude: 45.42, longitude: -75.69)
        XCTAssertNil(try EnvironmentCanadaProvider.parse(Self.sample, near: ottawa, now: now,
                                                         maxDistanceKm: 60, maxAge: 3 * 3600))
    }

    func testConditionText() {
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Light Drizzle"), .drizzle)
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Light Freezing Rain"), .freezingRain)
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Light Snowshower"), .snowShowers)
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Mostly Cloudy"), .partlyCloudy)
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Cloudy"), .overcast)
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Mainly Sunny"), .mainlyClear)
        XCTAssertEqual(EnvironmentCanadaProvider.condition(fromText: "Thunderstorm with light rain"), .thunderstorm)
        XCTAssertNil(EnvironmentCanadaProvider.condition(fromText: ""))
        XCTAssertNil(EnvironmentCanadaProvider.condition(fromText: "Not observed"))
    }

    func testStationCoordinates() {
        let c = EnvironmentCanadaProvider.coordinate(lat: "43.68N", lon: "79.63W")
        XCTAssertEqual(c?.latitude, 43.68)
        XCTAssertEqual(c?.longitude, -79.63)
    }

    func testOutsideCanadaSkipsNetwork() async throws {
        let provider = EnvironmentCanadaProvider(loader: { _ in
            XCTFail("should not fetch for a location outside Canada")
            throw URLError(.badURL)
        })
        let paris = Coordinate(latitude: 48.86, longitude: 2.35)
        let result = try await provider.observation(near: paris)
        XCTAssertNil(result)
    }

    func testApplyingObservationOverridesNowOnly() throws {
        let forecast = try OpenMeteoProvider.parse(OpenMeteoProviderTests.sample, fetchedAt: now)
        let o = try XCTUnwrap(EnvironmentCanadaProvider.parse(Self.sample, near: mississauga, now: now,
                                                              maxDistanceKm: 60, maxAge: 3 * 3600))
        let merged = forecast.applying(o)
        XCTAssertEqual(merged.current.temperature, 4.0)
        XCTAssertEqual(merged.current.feelsLikeKind, .windChill)
        XCTAssertEqual(merged.current.condition, .rain)
        XCTAssertEqual(merged.observation?.stationName, "Toronto Pearson Int'l Airport")
        XCTAssertEqual(merged.hourly, forecast.hourly)
        XCTAssertEqual(merged.daily, forecast.daily)
    }

    func testWindChillAndHumidex() {
        // Saad's case: 6 °C, 39 km/h at Burlington Lift Bridge. ECCC showed −6; the formula gives about +1.
        XCTAssertEqual(try XCTUnwrap(EnvironmentCanadaProvider.windChill(temperature: 6, windKmh: 39)), 0.7, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(EnvironmentCanadaProvider.windChill(temperature: -10, windKmh: 30)), -19.5, accuracy: 0.2)
        XCTAssertNil(EnvironmentCanadaProvider.windChill(temperature: 12, windKmh: 30))
        XCTAssertNil(EnvironmentCanadaProvider.windChill(temperature: 0, windKmh: 3))
        XCTAssertEqual(try XCTUnwrap(EnvironmentCanadaProvider.humidex(temperature: 30, dewpoint: 20)), 37.6, accuracy: 0.2)
        XCTAssertNil(EnvironmentCanadaProvider.humidex(temperature: 15, dewpoint: 12))
    }

    func testDistantStationOnlySetsCondition() throws {
        let forecast = try OpenMeteoProvider.parse(OpenMeteoProviderTests.sample, fetchedAt: now)
        let far = Observation(stationName: "Burlington Lift Bridge", observedAt: now, temperature: 6,
                              feelsLike: 0.7, feelsLikeKind: .windChill, humidity: 79, windSpeed: 39,
                              condition: .drizzle, conditionText: "Drizzle", distanceKm: 20)
        let merged = forecast.applying(far)
        XCTAssertEqual(merged.current.condition, .drizzle)
        XCTAssertEqual(merged.current.temperature, forecast.current.temperature)
        XCTAssertEqual(merged.current.feelsLike, forecast.current.feelsLike)
        XCTAssertEqual(merged.current.windSpeed, forecast.current.windSpeed)
        XCTAssertEqual(merged.observation?.stationName, "Burlington Lift Bridge")
    }

    func testSkyComesFromNearestReportingStation() {
        let bridge = Observation(stationName: "Burlington Lift Bridge", observedAt: now, temperature: 5.6,
                                 windSpeed: 39, distanceKm: 20)
        let pearson = Observation(stationName: "Toronto Pearson Int'l Airport", observedAt: now, temperature: 4.3,
                                  condition: .partlyCloudy, conditionText: "Mostly Cloudy", distanceKm: 21)
        let chosen = EnvironmentCanadaProvider.choose(from: [bridge, pearson])
        XCTAssertEqual(chosen?.stationName, "Toronto Pearson Int'l Airport")
        XCTAssertEqual(chosen?.conditionText, "Mostly Cloudy")

        // A local station without sky keeps its own readings and borrows the sky.
        var near = bridge
        near.distanceKm = 5
        let merged = EnvironmentCanadaProvider.choose(from: [pearson, near])
        XCTAssertEqual(merged?.stationName, "Burlington Lift Bridge")
        XCTAssertEqual(merged?.temperature, 5.6)
        XCTAssertEqual(merged?.conditionText, "Mostly Cloudy")

        // Nobody reports sky: still return the nearest.
        XCTAssertEqual(EnvironmentCanadaProvider.choose(from: [bridge])?.stationName, "Burlington Lift Bridge")
    }
}
