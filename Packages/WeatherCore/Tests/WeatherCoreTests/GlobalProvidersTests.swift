import XCTest
@testable import WeatherCore

final class GlobalProvidersTests: XCTestCase {
    let nyc = Coordinate(latitude: 40.75, longitude: -73.95)
    let berlin = Coordinate(latitude: 52.48, longitude: 13.40)

    func testRegions() {
        XCTAssertTrue(Region.inUS(nyc))
        XCTAssertFalse(Region.inUS(berlin))
        XCTAssertTrue(Region.inGermany(berlin))
        XCTAssertTrue(Region.inCanada(Coordinate(latitude: 43.513, longitude: -79.882)))
    }

    func testConditionText() {
        XCTAssertEqual(WeatherCondition(text: "Light Rain and Fog/Mist"), .rain)
        XCTAssertEqual(WeatherCondition(text: "Mostly Cloudy"), .overcast)
        XCTAssertEqual(WeatherCondition(text: "Partly Cloudy"), .partlyCloudy)
        XCTAssertEqual(WeatherCondition(text: "Clear"), .clear)
        XCTAssertNil(WeatherCondition(text: ""))
        XCTAssertEqual(WeatherCondition(metarWeather: "-RA BR", cover: "OVC"), .rain)
        XCTAssertEqual(WeatherCondition(metarWeather: "-SHSN", cover: "BKN"), .snow)
        XCTAssertEqual(WeatherCondition(metarWeather: nil, cover: "FEW"), .mainlyClear)
        XCTAssertEqual(WeatherCondition(metarWeather: "", cover: "CLR"), .clear)
    }

    func testHumidity() {
        XCTAssertEqual(relativeHumidity(temperature: 10, dewPoint: 10), 100, accuracy: 0.1)
        XCTAssertEqual(relativeHumidity(temperature: 20, dewPoint: 10), 52.5, accuracy: 1)
    }

    func testNWSStationsAndObservation() throws {
        let points = #"{"properties":{"observationStations":"https://api.weather.gov/gridpoints/OKX/34,37/stations"}}"#
        XCTAssertEqual(try NWSObservationProvider.stationsURL(Data(points.utf8))?.absoluteString,
                       "https://api.weather.gov/gridpoints/OKX/34,37/stations")

        let stations = #"""
        {"features":[
          {"geometry":{"type":"Point","coordinates":[-73.8803,40.7794]},"properties":{"stationIdentifier":"KLGA","name":"New York, La Guardia Airport"}},
          {"geometry":{"type":"Point","coordinates":[-73.9667,40.7833]},"properties":{"stationIdentifier":"KNYC","name":"New York City, Central Park"}},
          {"geometry":{"type":"Point","coordinates":[-75.0,42.0]},"properties":{"stationIdentifier":"KFAR","name":"Far away"}}
        ]}
        """#
        let list = try NWSObservationProvider.parseStations(Data(stations.utf8), near: nyc, maxDistanceKm: 40)
        XCTAssertEqual(list.map(\.id), ["KNYC", "KLGA"])

        let obs = #"""
        {"properties":{"timestamp":"2026-11-13T13:51:00+00:00","textDescription":"Mostly Cloudy",
          "temperature":{"unitCode":"wmoUnit:degC","value":8.3,"qualityControl":"V"},
          "dewpoint":{"unitCode":"wmoUnit:degC","value":2.1,"qualityControl":"V"},
          "windSpeed":{"unitCode":"wmoUnit:km_h-1","value":14.8,"qualityControl":"V"},
          "windDirection":{"unitCode":"wmoUnit:degree_(angle)","value":290,"qualityControl":"V"},
          "relativeHumidity":{"unitCode":"wmoUnit:percent","value":null,"qualityControl":"Z"}}}
        """#
        let now = EnvironmentCanadaProvider.parseDate("2026-11-13T14:00:00Z")!
        let o = try XCTUnwrap(NWSObservationProvider.parseObservation(Data(obs.utf8), station: list[0], now: now, maxAge: 7200))
        XCTAssertEqual(o.stationName, "New York City, Central Park")
        XCTAssertEqual(o.temperature, 8.3)
        XCTAssertEqual(o.windSpeed, 14.8)
        XCTAssertEqual(o.condition, .overcast)
        XCTAssertEqual(o.dataProvider, "NWS")
        XCTAssertEqual(o.humidity ?? 0, 65, accuracy: 2)

        let later = now.addingTimeInterval(3 * 3600)
        XCTAssertNil(try NWSObservationProvider.parseObservation(Data(obs.utf8), station: list[0], now: later, maxAge: 7200))
    }

    func testNWSAlerts() throws {
        let json = #"""
        {"features":[
          {"properties":{"id":"urn:a1","event":"Coastal Flood Statement","severity":"Minor","headline":"Coastal Flood Statement issued",
            "description":"Minor flooding possible.","instruction":"Avoid low roads.","areaDesc":"New York (Manhattan)",
            "effective":"2026-11-13T09:00:00-05:00","expires":"2026-11-13T18:00:00-05:00","ends":null,"status":"Actual","messageType":"Alert"}},
          {"properties":{"id":"urn:a2","event":"Wind Advisory","severity":"Moderate","status":"Actual","messageType":"Cancel",
            "expires":"2026-11-13T18:00:00-05:00"}},
          {"properties":{"id":"urn:a3","event":"Flood Warning","severity":"Severe","status":"Actual","messageType":"Alert",
            "expires":"2026-11-13T06:00:00-05:00"}}
        ]}
        """#
        let now = EnvironmentCanadaProvider.parseDate("2026-11-13T14:00:00Z")!
        let alerts = try NWSAlertProvider.parse(Data(json.utf8), now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].title, "Coastal Flood Statement")
        XCTAssertEqual(alerts[0].kind, .statement)
        XCTAssertEqual(alerts[0].risk, .yellow)
        XCTAssertTrue(alerts[0].text.contains("Avoid low roads."))
        XCTAssertEqual(alerts[0].source, "US National Weather Service")
    }

    func testBrightSky() throws {
        let json = #"""
        {"weather":{"source_id":1234,"timestamp":"2026-11-13T13:30:00+00:00","temperature":9.4,"relative_humidity":81,
          "wind_speed_10":18.4,"wind_direction_10":240,"condition":"dry","icon":"cloudy","visibility":30000},
         "sources":[{"id":1234,"station_name":"Berlin-Tempelhof","distance":2470.0}]}
        """#
        let now = EnvironmentCanadaProvider.parseDate("2026-11-13T14:00:00Z")!
        let o = try XCTUnwrap(BrightSkyProvider.parse(Data(json.utf8), now: now, maxAge: 7200))
        XCTAssertEqual(o.stationName, "Berlin-Tempelhof")
        XCTAssertEqual(o.distanceKm ?? 0, 2.47, accuracy: 0.01)
        XCTAssertEqual(o.condition, .overcast)
        XCTAssertEqual(o.dataProvider, "DWD")

        let alerts = #"""
        {"alerts":[
          {"id":1,"alert_id":"2.49.0.0.276.0.DWD.1","event_en":"wind gusts","headline_en":"Official WARNING of WIND GUSTS",
           "description_en":"Gusts up to 55 km/h.","instruction_en":null,"severity":"minor",
           "effective":"2026-11-13T10:00:00+00:00","expires":"2026-11-13T20:00:00+00:00"},
          {"id":2,"alert_id":"old","event_en":"frost","severity":"minor","expires":"2026-11-13T08:00:00+00:00"}
        ],"location":{"name":"Berlin"}}
        """#
        let list = try BrightSkyAlertProvider.parse(Data(alerts.utf8), now: now)
        XCTAssertEqual(list.map(\.title), ["Wind gusts"])
        XCTAssertEqual(list[0].risk, .yellow)
        XCTAssertEqual(list[0].source, "Deutscher Wetterdienst")
    }

    func testMETAR() throws {
        let json = #"""
        [{"icaoId":"KLGA","name":"New York/La Guardia Arpt, NY, US","lat":40.7794,"lon":-73.8803,"obsTime":1794578460,
          "temp":8.9,"dewp":1.1,"wdir":300,"wspd":12,"visib":"10+","wxString":null,"cover":"BKN"},
         {"icaoId":"KJFK","name":"New York/JF Kennedy Intl, NY, US","lat":40.6392,"lon":-73.7639,"obsTime":1794578460,
          "temp":9.4,"dewp":2.2,"wdir":"VRB","wspd":3,"visib":6,"wxString":"-RA","cover":"OVC"}]
        """#
        let now = Date(timeIntervalSince1970: 1794578460 + 600)
        let o = try XCTUnwrap(METARProvider.parse(Data(json.utf8), near: nyc, now: now, maxDistanceKm: 40, maxAge: 10800))
        XCTAssertEqual(o.stationName, "New York/La Guardia Arpt")
        XCTAssertEqual(o.windSpeed ?? 0, 22.2, accuracy: 0.1)
        XCTAssertEqual(o.windDirection, 300)
        XCTAssertEqual(o.condition, .partlyCloudy)
        XCTAssertEqual(o.dataProvider, "METAR")
    }

    struct Fixed: ObservationProvider {
        let attribution = "test"
        let result: Observation?
        func observation(near coordinate: Coordinate) async throws -> Observation? { result }
    }

    func testWorldPicksNearest() async throws {
        let now = Date()
        let near = Observation(stationName: "Near", observedAt: now, temperature: 1, distanceKm: 5)
        let far = Observation(stationName: "Far", observedAt: now, temperature: 2, distanceKm: 20)
        let world = WorldObservationProvider(canada: Fixed(result: nil), us: Fixed(result: far),
                                             germany: Fixed(result: nil), airports: Fixed(result: near))
        let o = try await world.observation(near: nyc)
        XCTAssertEqual(o?.stationName, "Near")
    }
}
