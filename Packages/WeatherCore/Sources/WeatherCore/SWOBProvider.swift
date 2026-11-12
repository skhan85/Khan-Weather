import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Automatic station readings from Environment Canada's SWOB feed (collection `swob-realtime`).
/// Besides ECCC's own stations it carries partner networks such as Ontario MTO road weather
/// stations, which are often much closer to the user than any city-page station. Free, no key.
/// SWOB stations report temperature and wind but rarely the sky, so this provider returns no condition.
public struct SWOBProvider: ObservationProvider {
    public typealias DataLoader = OpenMeteoProvider.DataLoader

    public let attribution = "Observations: Environment and Climate Change Canada and partners"

    /// Only stations this close stand in for the user's own spot.
    public var maxStationDistanceKm: Double = Observation.localRadiusKm
    public var maxAge: TimeInterval = 90 * 60

    private let baseURL: URL
    private let loader: DataLoader

    public init(
        baseURL: URL = URL(string: "https://api.weather.gc.ca/collections/swob-realtime/items")!,
        loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.loader = loader
    }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        guard EnvironmentCanadaProvider.mightBeInCanada(coordinate) else { return nil }
        let now = Date()
        let (data, response) = try await loader(URLRequest(url: url(for: coordinate, now: now), timeoutInterval: 20))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return try Self.parse(data, near: coordinate, now: now, maxDistanceKm: maxStationDistanceKm, maxAge: maxAge)
    }

    func url(for c: Coordinate, now: Date) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // About 22 km each way; enough to cover the local radius.
        let bbox = [c.longitude - 0.28, c.latitude - 0.2, c.longitude + 0.28, c.latitude + 0.2]
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        components.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "datetime", value: f.string(from: now.addingTimeInterval(-maxAge)) + "/.."),
            // Minutely stations would otherwise flood the page with near-identical records.
            URLQueryItem(name: "_is-minutely_obs-value", value: "false"),
            URLQueryItem(name: "limit", value: "500"),
        ]
        return components.url!
    }

    // MARK: - Parsing

    static func parse(_ data: Data, near coordinate: Coordinate, now: Date,
                      maxDistanceKm: Double, maxAge: TimeInterval) throws -> Observation? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else {
            throw ForecastError.missingData("features")
        }
        // Newest record per station, then the nearest station.
        var newest: [String: Observation] = [:]
        for feature in features {
            guard let p = feature["properties"] as? [String: Any],
                  let station = EnvironmentCanadaProvider.pointCoordinate(feature["geometry"]),
                  var o = observation(from: p) else { continue }
            guard now.timeIntervalSince(o.observedAt) <= maxAge else { continue }
            let distance = EnvironmentCanadaProvider.distanceKm(coordinate, station)
            guard distance <= maxDistanceKm else { continue }
            o.distanceKm = distance
            let key = (p["msc_id-value"] as? String) ?? o.stationName
            if let existing = newest[key], existing.observedAt >= o.observedAt { continue }
            newest[key] = o
        }
        return newest.values.min { ($0.distanceKm ?? 0) < ($1.distanceKm ?? 0) }
    }

    static func observation(from p: [String: Any]) -> Observation? {
        guard let t = value(p["air_temp"]), (-60...50).contains(t),
              let stamp = p["obs_date_tm"] as? String,
              let observedAt = EnvironmentCanadaProvider.parseDate(stamp) else { return nil }
        let name = (p["stn_nam-value"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Nearby station"
        if name.uppercased().contains("TEST") { return nil }

        // Wind field names depend on the station type; take the first averaged speed it has.
        let wind = firstValue(p, prefixes: ["avg_wnd_spd_10m_pst10mts", "avg_wnd_spd_10m_pst2mts",
                                            "avg_wnd_spd_10m_pst1mt", "avg_wnd_spd"])
            .flatMap { (0...250).contains($0) ? $0 : nil }
        let direction = firstValue(p, prefixes: ["avg_wnd_dir_10m_pst10mts", "avg_wnd_dir_10m_pst2mts",
                                                 "avg_wnd_dir_10m_pst1mt", "avg_wnd_dir"])
        let humidity = value(p["rel_hum"]).flatMap { (0...100).contains($0) ? $0 : nil }

        var feelsLike: Double?
        var kind: FeelsLikeKind?
        if let chill = EnvironmentCanadaProvider.windChill(temperature: t, windKmh: wind) {
            feelsLike = chill; kind = .windChill
        } else if let hx = EnvironmentCanadaProvider.humidex(temperature: t, dewpoint: value(p["dwpt_temp"])) {
            feelsLike = hx; kind = .humidex
        }

        var o = Observation(stationName: name, observedAt: observedAt, temperature: t,
                            feelsLike: feelsLike, feelsLikeKind: kind, humidity: humidity,
                            windSpeed: wind, windDirection: direction)
        o.dataProvider = p["data_pvdr-value"] as? String
        return o
    }

    static func value(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Exact key first, then any key starting with the prefix that isn't a -uom/-qa/flag sibling.
    static func firstValue(_ p: [String: Any], prefixes: [String]) -> Double? {
        for prefix in prefixes {
            if let v = value(p[prefix]) { return v }
        }
        for prefix in prefixes {
            for key in p.keys.sorted() where key.hasPrefix(prefix) && !key.contains("-") {
                if let v = value(p[key]) { return v }
            }
        }
        return nil
    }
}

/// Canada: temperature, wind and feels-like from the nearest SWOB station within the local radius,
/// and the sky from the nearest city-page station that reports one.
public struct CanadaObservationProvider: ObservationProvider {
    public let attribution = "Observations: Environment and Climate Change Canada and partners"
    private let local: ObservationProvider
    private let partners: ObservationProvider
    private let sky: ObservationProvider

    public init(local: ObservationProvider = SWOBProvider(),
                partners: ObservationProvider = PartnerStationProvider(),
                sky: ObservationProvider = EnvironmentCanadaProvider()) {
        self.local = local
        self.partners = partners
        self.sky = sky
    }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        async let nearby = try? local.observation(near: coordinate)
        async let partner = try? partners.observation(near: coordinate)
        async let city = try? sky.observation(near: coordinate)
        return Self.combine(local: Self.nearest(await nearby ?? nil, await partner ?? nil), sky: await city ?? nil)
    }

    static func nearest(_ a: Observation?, _ b: Observation?) -> Observation? {
        guard let a else { return b }
        guard let b else { return a }
        return (a.distanceKm ?? .infinity) <= (b.distanceKm ?? .infinity) ? a : b
    }

    static func combine(local: Observation?, sky: Observation?) -> Observation? {
        guard var local, local.isLocal else { return sky }
        guard let sky else { return local }
        if sky.isLocal {
            // Both nearby: the city-page station is the more trusted one, unless the SWOB one is much closer.
            let much = (local.distanceKm ?? 0) + 5 < (sky.distanceKm ?? 0)
            if !much { return sky }
        }
        local.condition = sky.condition
        local.conditionText = sky.conditionText
        local.skyStationName = sky.stationName
        return local
    }
}
