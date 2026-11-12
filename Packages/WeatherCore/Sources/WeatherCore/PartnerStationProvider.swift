import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Partner stations (e.g. Ontario MTO road weather stations) that Environment Canada publishes on its
/// Datamart as SWOB-ML files but does not carry in the `swob-realtime` API. CR-27 Campbellville is one.
///
/// 1. Find nearby partner stations with the `swob-partner-stations` API (bbox query).
/// 2. For the nearest, list today's folder on dd.weather.gc.ca and fetch the newest SWOB-ML file (~6 KB).
public struct PartnerStationProvider: ObservationProvider {
    public typealias DataLoader = OpenMeteoProvider.DataLoader

    public let attribution = "Observations: Environment and Climate Change Canada partners"
    public var maxStationDistanceKm: Double = Observation.localRadiusKm
    public var maxAge: TimeInterval = 90 * 60

    private let stationsURL: URL
    private let datamartURL: URL
    private let loader: DataLoader

    public init(
        stationsURL: URL = URL(string: "https://api.weather.gc.ca/collections/swob-partner-stations/items")!,
        datamartURL: URL = URL(string: "https://dd.weather.gc.ca/today/observations/swob-ml/partners/")!,
        loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }
    ) {
        self.stationsURL = stationsURL
        self.datamartURL = datamartURL
        self.loader = loader
    }

    struct Station: Equatable {
        var name: String
        var folder: String      // e.g. "on-mto"
        var id: String          // e.g. "roncr27"
        var coordinate: Coordinate
        var distanceKm: Double
    }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        guard EnvironmentCanadaProvider.mightBeInCanada(coordinate) else { return nil }
        let stations = try Self.parseStations(try await get(stationsQuery(for: coordinate)), near: coordinate,
                                              maxDistanceKm: maxStationDistanceKm)
        let now = Date()
        // Nearest first; a station that has gone quiet falls through to the next one.
        for station in stations.prefix(3) {
            if var o = try? await latest(for: station, now: now) {
                o.distanceKm = station.distanceKm
                return o
            }
        }
        return nil
    }

    private func latest(for station: Station, now: Date) async throws -> Observation? {
        let calendar = Self.utcCalendar
        // Just after midnight UTC today's folder may still be empty.
        for day in [now, now.addingTimeInterval(-86400)] {
            let folder = datamartURL
                .appendingPathComponent(station.folder)
                .appendingPathComponent(Self.dayString(day, calendar: calendar))
                .appendingPathComponent(station.id, isDirectory: true)
            guard let listing = try? await get(folder),
                  let file = Self.newestFile(inListing: listing) else { continue }
            let xml = try await get(folder.appendingPathComponent(file))
            guard let o = Self.parseSWOBML(xml), now.timeIntervalSince(o.observedAt) <= maxAge else { return nil }
            return o
        }
        return nil
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await loader(URLRequest(url: url, timeoutInterval: 15))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return data
    }

    func stationsQuery(for c: Coordinate) -> URL {
        var components = URLComponents(url: stationsURL, resolvingAgainstBaseURL: false)!
        let bbox = [c.longitude - 0.28, c.latitude - 0.2, c.longitude + 0.28, c.latitude + 0.2]
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "limit", value: "100"),
        ]
        return components.url!
    }

    // MARK: - Parsing

    static func parseStations(_ data: Data, near coordinate: Coordinate, maxDistanceKm: Double) throws -> [Station] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else {
            throw ForecastError.missingData("features")
        }
        var stations: [Station] = []
        for feature in features {
            guard let p = feature["properties"] as? [String: Any],
                  let point = EnvironmentCanadaProvider.pointCoordinate(feature["geometry"]),
                  let iata = (p["iata_id"] ?? p["iata"]) as? String, !iata.isEmpty,
                  let msc = (p["msc_id"] ?? p["msc_id-value"]) as? String,
                  let folder = partnerFolder(mscID: msc) else { continue }
            let name = ((p["name_en"] ?? p["name"]) as? String) ?? iata
            if name.uppercased().contains("TEST") { continue }
            let distance = EnvironmentCanadaProvider.distanceKm(coordinate, point)
            guard distance <= maxDistanceKm else { continue }
            stations.append(Station(name: name, folder: folder, id: iata.lowercased(),
                                    coordinate: point, distanceKm: distance))
        }
        return stations.sorted { $0.distanceKm < $1.distanceKm }
    }

    /// "ON_MTO_CR-27" → "on-mto": the Datamart folder for that partner network.
    static func partnerFolder(mscID: String) -> String? {
        let parts = mscID.split(separator: "_")
        guard parts.count >= 3 else { return nil }
        return "\(parts[0])-\(parts[1])".lowercased()
    }

    /// Newest `…-swob.xml` file in an Apache-style directory listing. Names start with the
    /// observation time (YYYY-MM-DD-HHMM), so the largest name is the newest.
    static func newestFile(inListing data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"href="([^"/]+-swob\.xml)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range)
            .compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } }
            .max()
    }

    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", d.year!, d.month!, d.day!)
    }

    /// SWOB-ML: every value is `<element name="air_temp" uom="°C" value="4.4">` with a child
    /// `<qualifier name="qa_summary" value="100"/>`. Missing values are "MSNG"; qa_summary other
    /// than 100 means the value failed quality control (e.g. a 727.9 °C road sensor).
    static func parseSWOBML(_ data: Data) -> Observation? {
        let reader = SWOBMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let v = reader.values

        func number(_ name: String) -> Double? {
            guard let raw = v[name], raw != "MSNG" else { return nil }
            return Double(raw)
        }
        guard let t = number("air_temp"), (-60...50).contains(t),
              let stamp = v["date_tm"], let observedAt = EnvironmentCanadaProvider.parseDate(stamp) else { return nil }

        let wind = (number("avg_wnd_spd_10m_pst10mts") ?? number("avg_wnd_spd_10m_pst2mts")
                    ?? number("avg_wnd_spd_10m_pst1mt")).flatMap { (0...250).contains($0) ? $0 : nil }
        let direction = number("avg_wnd_dir_10m_pst10mts") ?? number("avg_wnd_dir_10m_pst2mts")
            ?? number("avg_wnd_dir_10m_pst1mt")
        let humidity = number("rel_hum").flatMap { (0...100).contains($0) ? $0 : nil }

        var feelsLike: Double?
        var kind: FeelsLikeKind?
        if let chill = EnvironmentCanadaProvider.windChill(temperature: t, windKmh: wind) {
            feelsLike = chill; kind = .windChill
        } else if let hx = EnvironmentCanadaProvider.humidex(temperature: t, dewpoint: number("dwpt_temp")) {
            feelsLike = hx; kind = .humidex
        }

        var o = Observation(stationName: v["stn_nam"] ?? "Nearby station", observedAt: observedAt,
                            temperature: t, feelsLike: feelsLike, feelsLikeKind: kind,
                            humidity: humidity, windSpeed: wind, windDirection: direction)
        if let msc = v["msc_id"], let folder = partnerFolder(mscID: msc) {
            o.dataProvider = folder.uppercased()   // "ON-MTO"
        }
        return o
    }
}

/// Collects `element` name → value, dropping values whose qa_summary isn't 100.
private final class SWOBMLReader: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var current: (name: String, value: String)?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "element", let name = attributes["name"], let value = attributes["value"] {
            current = (name, value)
            if values[name] == nil { values[name] = value }
        } else if local == "qualifier", attributes["name"] == "qa_summary", let current,
                  let qa = attributes["value"], qa != "100", qa != "MSNG" {
            values[current.name] = nil
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "element" { current = nil }
    }
}
