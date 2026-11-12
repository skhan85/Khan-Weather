import XCTest
@testable import WeatherCore

final class PartnerStationProviderTests: XCTestCase {
    /// Trimmed from 2026-11-12-1809-on-mto-roncr27-AUTO-swob.xml on dd.weather.gc.ca.
    static let swobML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <om:ObservationCollection xmlns="http://dms.ec.gc.ca/schema/point-observation/2.0" xmlns:om="http://www.opengis.net/om/1.0" xmlns:gml="http://www.opengis.net/gml">
     <om:member><om:Observation>
      <om:metadata><set><identification-elements>
       <element name="stn_nam" uom="unitless" value="CR-27 Campbellville"/>
       <element name="msc_id" uom="unitless" value="ON_MTO_CR-27"/>
       <element name="lat" uom="°" value="43.5037"/>
       <element name="long" uom="°" value="-79.95725"/>
       <element name="date_tm" uom="datetime" value="2026-11-12T18:09:00.000Z"/>
      </identification-elements></set></om:metadata>
      <om:result><elements>
       <element name="air_temp" uom="°C" value="4.4"><qualifier name="qa_summary" uom="unitless" value="100"/></element>
       <element name="dwpt_temp" uom="°C" value="0.6"><qualifier name="qa_summary" uom="unitless" value="100"/></element>
       <element name="rel_hum" uom="%" value="76"><qualifier name="qa_summary" uom="unitless" value="100"/></element>
       <element name="avg_wnd_spd_10m_pst2mts" uom="km/h" value="16.2"><qualifier name="qa_summary" uom="unitless" value="100"/></element>
       <element name="avg_wnd_dir_10m_pst2mts" uom="°" value="24"><qualifier name="qa_summary" uom="unitless" value="100"/></element>
       <element name="int_pvmnt_temp_1" uom="°C" value="727.9"><qualifier name="qa_summary" uom="unitless" value="0"/></element>
       <element name="vis" uom="km" value="MSNG"/>
      </elements></om:result>
     </om:Observation></om:member>
    </om:ObservationCollection>
    """.data(using: .utf8)!

    static let listing = """
    <html><body><pre>
    <a href="../">../</a>
    <a href="2026-11-12-1751-on-mto-roncr27-AUTO-swob.xml">2026-11-12-1751-on-mto-roncr27-AUTO-swob.xml</a> 12-Nov-2026 18:03 5.9K
    <a href="2026-11-12-1809-on-mto-roncr27-AUTO-swob.xml">2026-11-12-1809-on-mto-roncr27-AUTO-swob.xml</a> 12-Nov-2026 18:16 5.9K
    <a href="2026-11-12-1800-on-mto-roncr27-AUTO-swob.xml">2026-11-12-1800-on-mto-roncr27-AUTO-swob.xml</a> 12-Nov-2026 18:07 5.9K
    </pre></body></html>
    """.data(using: .utf8)!

    static let stations = """
    {"type": "FeatureCollection", "features": [
      {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-79.95725, 43.5037, 200]},
       "properties": {"iata_id": "RONCR27", "name_en": "CR-27 Campbellville", "msc_id": "ON_MTO_CR-27"}},
      {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-79.88, 43.52, 190]},
       "properties": {"iata_id": "RONTST1", "name_en": "MTO TEST SITE", "msc_id": "ON_MTO_TST-1"}}
    ]}
    """.data(using: .utf8)!

    let milton = Coordinate(latitude: 43.4733, longitude: -79.8640)

    func testParsesSWOBMLAndDropsFailedQC() throws {
        let o = try XCTUnwrap(PartnerStationProvider.parseSWOBML(Self.swobML))
        XCTAssertEqual(o.stationName, "CR-27 Campbellville")
        XCTAssertEqual(o.temperature, 4.4)
        XCTAssertEqual(o.humidity, 76)
        XCTAssertEqual(o.windSpeed, 16.2)
        XCTAssertEqual(o.windDirection, 24)
        XCTAssertEqual(o.feelsLikeKind, .windChill)
        XCTAssertEqual(o.dataProvider, "ON-MTO")
        XCTAssertEqual(o.observedAt, ISO8601DateFormatter().date(from: "2026-11-12T18:09:00Z"))
    }

    func testNewestFileInListing() {
        XCTAssertEqual(PartnerStationProvider.newestFile(inListing: Self.listing),
                       "2026-11-12-1809-on-mto-roncr27-AUTO-swob.xml")
    }

    func testStationsSkipTestSitesAndMapFolders() throws {
        let s = try PartnerStationProvider.parseStations(Self.stations, near: milton, maxDistanceKm: 15)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.id, "roncr27")
        XCTAssertEqual(s.first?.folder, "on-mto")
        XCTAssertEqual(try XCTUnwrap(s.first?.distanceKm), 8.2, accuracy: 0.3)
    }

    func testFetchesNewestFileFromStationFolder() async throws {
        let requested = URLLog()
        let provider = PartnerStationProvider(loader: { request in
            let url = request.url!.absoluteString
            await requested.add(url)
            let body: Data
            if url.contains("swob-partner-stations") { body = Self.stations }
            else if url.hasSuffix(".xml") { body = Self.swobML }
            else { body = Self.listing }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        // The sample file is from 18:09Z, so with the real clock it is too old to be returned;
        // check that the right station folder and file were requested.
        _ = try await provider.observation(near: milton)
        let urls = await requested.urls
        XCTAssertTrue(urls.contains { $0.contains("/partners/on-mto/") && $0.hasSuffix("/roncr27/") })
        XCTAssertTrue(urls.contains { $0.hasSuffix("/roncr27/2026-11-12-1809-on-mto-roncr27-AUTO-swob.xml") })
    }

    func testNearestOfTwoLocalSources() {
        let now = Date()
        let a = Observation(stationName: "A", observedAt: now, temperature: 1, distanceKm: 12)
        let b = Observation(stationName: "B", observedAt: now, temperature: 2, distanceKm: 8)
        XCTAssertEqual(CanadaObservationProvider.nearest(a, b)?.stationName, "B")
        XCTAssertEqual(CanadaObservationProvider.nearest(nil, b)?.stationName, "B")
        XCTAssertEqual(CanadaObservationProvider.nearest(a, nil)?.stationName, "A")
    }
}

private actor URLLog {
    var urls: [String] = []
    func add(_ url: String) { urls.append(url) }
}
