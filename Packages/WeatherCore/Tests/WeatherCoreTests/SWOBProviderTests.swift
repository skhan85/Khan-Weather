import XCTest
@testable import WeatherCore

final class SWOBProviderTests: XCTestCase {
    /// Shape of api.weather.gc.ca swob-realtime items (flat properties, Point [lon, lat, elev]).
    /// Field names follow samples taken 2026-11-12; values trimmed.
    static let sample = """
    {
      "type": "FeatureCollection",
      "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-79.955, 43.49, 200]},
         "properties": {"stn_nam-value": "CR-27 Campbellville", "msc_id-value": "ON_MTO_CR-27",
           "data_pvdr-value": "ON-MTO", "obs_date_tm": "2026-11-12T14:23:00Z",
           "air_temp": 2.9, "rel_hum": 90, "dwpt_temp": 1.4, "avg_wnd_spd_10m_pst10mts": 15.0,
           "avg_wnd_spd_10m_pst10mts-uom": "km/h", "avg_wnd_dir_10m_pst10mts": 40}},
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-79.955, 43.49, 200]},
         "properties": {"stn_nam-value": "CR-27 Campbellville", "msc_id-value": "ON_MTO_CR-27",
           "data_pvdr-value": "ON-MTO", "obs_date_tm": "2026-11-12T14:33:00Z",
           "air_temp": 2.7, "rel_hum": 91, "avg_wnd_spd_10m_pst10mts": 18.0, "avg_wnd_dir_10m_pst10mts": 45}},
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-79.88, 43.29, 102]},
         "properties": {"stn_nam-value": "HAMILTON RBG CS", "msc_id-value": "6153301",
           "obs_date_tm": "2026-11-12T14:00:00Z", "air_temp": 5.5, "avg_wnd_spd_10m_pst2mts": 25.0}},
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-79.86, 43.52, 190]},
         "properties": {"stn_nam-value": "Broken sensor", "msc_id-value": "X1",
           "obs_date_tm": "2026-11-12T14:30:00Z", "air_temp": 727.9}}
      ]
    }
    """.data(using: .utf8)!

    let now = ISO8601DateFormatter().date(from: "2026-11-12T14:40:00Z")!
    let milton = Coordinate(latitude: 43.513, longitude: -79.882)

    func testPicksNewestReadingOfNearestValidStation() throws {
        let o = try XCTUnwrap(SWOBProvider.parse(Self.sample, near: milton, now: now, maxDistanceKm: 15, maxAge: 5400))
        XCTAssertEqual(o.stationName, "CR-27 Campbellville")
        XCTAssertEqual(o.temperature, 2.7)
        XCTAssertEqual(o.windSpeed, 18)
        XCTAssertEqual(o.windDirection, 45)
        XCTAssertEqual(o.humidity, 91)
        XCTAssertEqual(o.dataProvider, "ON-MTO")
        XCTAssertEqual(o.feelsLikeKind, .windChill)
        XCTAssertNil(o.condition)
        XCTAssertEqual(try XCTUnwrap(o.distanceKm), 6.3, accuracy: 0.5)
    }

    func testFallbackWindFieldAndDistanceLimit() throws {
        // Hamilton RBG is ~25 km away: outside the local radius.
        XCTAssertNil(try SWOBProvider.parse(Self.sample, near: Coordinate(latitude: 43.30, longitude: -79.70),
                                            now: now, maxDistanceKm: 10, maxAge: 5400))
        let o = try XCTUnwrap(SWOBProvider.parse(Self.sample, near: Coordinate(latitude: 43.30, longitude: -79.88),
                                                 now: now, maxDistanceKm: 15, maxAge: 5400))
        XCTAssertEqual(o.stationName, "HAMILTON RBG CS")
        XCTAssertEqual(o.windSpeed, 25)
    }

    func testCombineTakesReadingsLocallyAndSkyFromCityPage() {
        let local = Observation(stationName: "CR-27 Campbellville", observedAt: now, temperature: 2.7,
                                windSpeed: 18, distanceKm: 6)
        let sky = Observation(stationName: "Toronto Pearson Int'l Airport", observedAt: now, temperature: 4.3,
                              condition: .rain, conditionText: "Light Rain", distanceKm: 27)
        let merged = CanadaObservationProvider.combine(local: local, sky: sky)
        XCTAssertEqual(merged?.stationName, "CR-27 Campbellville")
        XCTAssertEqual(merged?.temperature, 2.7)
        XCTAssertEqual(merged?.conditionText, "Light Rain")
        XCTAssertEqual(merged?.skyStationName, "Toronto Pearson Int'l Airport")

        XCTAssertEqual(CanadaObservationProvider.combine(local: nil, sky: sky)?.stationName, sky.stationName)
        var far = local
        far.distanceKm = 30
        XCTAssertEqual(CanadaObservationProvider.combine(local: far, sky: sky)?.stationName, sky.stationName)
    }

    func testURLFiltersMinutelyAndRecent() {
        let url = SWOBProvider().url(for: milton, now: now).absoluteString
        XCTAssertTrue(url.contains("_is-minutely_obs-value=false"))
        XCTAssertTrue(url.contains("datetime=2026-11-12T13:10:00Z/.."))
    }
}
