import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Netatmo personal weather stations, served by the family relay on Saad's Raspberry Pi.
// The relay holds the Netatmo key, so the app needs none. When the Pi is off, this returns nil.

public struct NetatmoStation: Decodable, Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let distance_km: Double?
    public let city: String?
    public let temperature: Double?
    public let humidity: Double?
    public let observed: Double?
    public let rain_60min: Double?
    public let wind_strength: Double?
    public let wind_angle: Double?
    public let gust_strength: Double?
}

public struct NetatmoRelayProvider: ObservationProvider {
    public let attribution = "Personal weather stations: Netatmo"
    /// Fixed https address of the relay (Tailscale Funnel on the Pi).
    public static let defaultBaseURL = URL(string: "https://weather-relay.khanofmilton.ca/v1/netatmo")!

    private let baseURL: URL
    private let loader: HTTPLoader
    /// Stations farther than this don't count as "here".
    let radiusKm: Double = 8
    let maxAge: TimeInterval = 3600

    public init(baseURL: URL = defaultBaseURL, loader: @escaping HTTPLoader = defaultLoader) {
        self.baseURL = baseURL
        self.loader = loader
    }

    /// Pause before asking the relay a second time.
    static let retryDelay: TimeInterval = 1.5

    /// The first call after the app has been closed for a while can come back empty: the relay
    /// errors or hands back readings that are too old while it fetches new ones from Netatmo.
    /// Then the app fell back to the official station 8 km away for that whole load (26 Nov:
    /// Campbellville 0° and snow on opening, 3 home stations 3 km away at 2° after a pull to
    /// refresh). One quick second try fixes that. It isn't made when the relay answered with
    /// fresh data and there simply are no stations near.
    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        do {
            let (o, staleOnly) = try await fetch(near: coordinate)
            if o != nil || !staleOnly { return o }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall through to one retry.
        }
        try await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
        return try await fetch(near: coordinate).observation
    }

    private func fetch(near coordinate: Coordinate) async throws -> (observation: Observation?, staleOnly: Bool) {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.4f", coordinate.latitude)),
                            URLQueryItem(name: "lon", value: String(format: "%.4f", coordinate.longitude))]
        var request = URLRequest(url: parts.url!, timeoutInterval: 6)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ForecastError.httpStatus(http.statusCode) }
        let now = Date()
        let o = try Self.parse(data, near: coordinate, now: now, radiusKm: radiusKm, maxAge: maxAge)
        return (o, o == nil && Self.hasOnlyStaleStations(data, near: coordinate, now: now, radiusKm: radiusKm, maxAge: maxAge))
    }

    /// True when the relay listed stations within the radius but every one was too old to use.
    static func hasOnlyStaleStations(_ data: Data, near c: Coordinate, now: Date, radiusKm: Double, maxAge: TimeInterval) -> Bool {
        struct R: Decodable { let stations: [NetatmoStation] }
        guard let stations = try? JSONDecoder().decode(R.self, from: data).stations else { return false }
        let near = stations.filter {
            $0.temperature != nil &&
                EnvironmentCanadaProvider.distanceKm(c, Coordinate(latitude: $0.lat, longitude: $0.lon)) <= radiusKm
        }
        return !near.isEmpty && near.allSatisfy { s in
            s.observed.map { now.timeIntervalSince(Date(timeIntervalSince1970: $0)) >= maxAge } ?? true
        }
    }

    /// How far out to look for stations to make up three when fewer are within the radius.
    static let fillRadiusKm: Double = 10

    /// Degrees from the neighbourhood median beyond which a station is ignored.
    static let outlierLimit: Double = 2.5

    /// Median of the (up to) three nearest fresh stations, so one sensor sitting in the sun
    /// or by a dryer vent can't skew "now".
    static func parse(_ data: Data, near c: Coordinate, now: Date, radiusKm: Double, maxAge: TimeInterval) throws -> Observation? {
        struct R: Decodable { let stations: [NetatmoStation] }
        let all = try JSONDecoder().decode(R.self, from: data).stations.compactMap { s -> (NetatmoStation, Double, Date)? in
            guard s.temperature != nil, let t = s.observed else { return nil }
            let time = Date(timeIntervalSince1970: t)
            let d = EnvironmentCanadaProvider.distanceKm(c, Coordinate(latitude: s.lat, longitude: s.lon))
            guard d <= max(radiusKm, Self.fillRadiusKm), now.timeIntervalSince(time) < maxAge else { return nil }
            return (s, d, time)
        }.sorted { $0.1 < $1.1 }
        // Stations within the radius count; with fewer than three, the next nearest out to
        // `fillRadiusKm` make up three, since the middle of three is far steadier than the
        // average of two.
        let within = all.filter { $0.1 <= radiusKm }
        guard !within.isEmpty else { return nil }
        let fresh = within.count >= 3 ? within : Array(all.prefix(3))
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let v = values.sorted()
            return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        }
        // Home stations in the sun or by a wall read warm. With enough neighbours, drop any that
        // disagree with the local median by more than a few degrees.
        var agreeing = fresh
        if fresh.count >= 3, let mid = median(fresh.compactMap { $0.0.temperature }) {
            agreeing = fresh.filter { abs(($0.0.temperature ?? mid) - mid) <= Self.outlierLimit }
        }
        let nearest = Array(agreeing.prefix(3))
        guard let first = nearest.first else { return nil }
        let temperature = median(nearest.compactMap { $0.0.temperature })!
        let wind = fresh.first { $0.0.wind_strength != nil }?.0
        let name = nearest.count == 1 ? "Netatmo station" : "\(nearest.count) Netatmo stations"
        var o = Observation(stationName: name + (first.0.city.map { " in \($0)" } ?? ""),
                            observedAt: nearest.map(\.2).min() ?? first.2,
                            temperature: (temperature * 10).rounded() / 10,
                            humidity: median(nearest.compactMap { $0.0.humidity }),
                            windSpeed: wind?.wind_strength, windDirection: wind?.wind_angle,
                            distanceKm: first.1)
        o.windGusts = wind?.gust_strength
        o.dataProvider = "NETATMO"
        o.stationTemperatures = agreeing.prefix(5).compactMap { $0.0.temperature }
        let gauges = within.compactMap(\.0.rain_60min)
        if !gauges.isEmpty {
            o.rainGauges = gauges.count
            o.rainLastHourMm = gauges.max()
        }
        return o
    }
}

/// Official observations for the sky (rain, snow, cloud), with nearby Netatmo stations for
/// temperature and humidity when there are any within a few km.
public struct HyperlocalObservationProvider: ObservationProvider {
    public let attribution = "Observations: national weather services, airports and Netatmo stations"
    private let official: ObservationProvider
    private let netatmo: ObservationProvider

    public init(official: ObservationProvider = WorldObservationProvider(),
                netatmo: ObservationProvider = NetatmoRelayProvider()) {
        self.official = official
        self.netatmo = netatmo
    }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        async let a = try? official.observation(near: coordinate)
        // Home stations get a little under the app's 8 s wait, so a slow relay still leaves the
        // official reading rather than nothing.
        let netatmo = self.netatmo
        async let b = Deadline.run(Self.homeDeadline) { try? await netatmo.observation(near: coordinate) }
        let base = await a ?? nil
        guard let local = await b ?? nil else { return base }
        return Self.merge(official: base, netatmo: local)
    }

    static let homeDeadline: Double = 7

    /// Further than this from a nearby official station, the Netatmo reading is set aside.
    static let officialLimit: Double = 2
    /// Past this gap from a road-weather station, the models decide who is right (`Forecast.tieBroken`).
    public static let tieBreakGap: Double = 3

    static func merge(official base: Observation?, netatmo local: Observation) -> Observation {
        var local = local
        let temps = (local.stationTemperatures ?? []).sorted()
        let tightCluster = temps.count >= 3
            && (temps.last! - temps.first!) <= 2.5
            && (0...(temps.count - 3)).contains { temps[$0 + 2] - temps[$0] <= 1.0 }
        let limit: Double = base?.dataProvider == "ON-MTO"
            ? ((tightCluster && (base?.distanceKm ?? 0) > 5) ? 4.5 : 3.0)
            : officialLimit
        if let base, (base.distanceKm ?? 0) <= 10, abs(base.temperature - local.temperature) > limit,
           base.observedAt.timeIntervalSince(local.observedAt) > -3600 {
            // Usually one or two of the nearest stations are in the sun (15 Nov, 4 pm: 7.1, 9.4,
            // 9.9, 9.5 and 16.4° while Campbellville read 6°). Keep the ones that agree with the
            // official station rather than dropping every home station; if none do, it wins.
            let agreeing = (local.stationTemperatures ?? []).filter { abs($0 - base.temperature) <= limit }
            guard !agreeing.isEmpty else { return base }
            let v = Array(agreeing.prefix(3)).sorted()
            let mid = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
            local.temperature = (mid * 10).rounded() / 10
            local.stationTemperatures = agreeing
            let place = local.stationName.range(of: " in ").map { String(local.stationName[$0.lowerBound...]) } ?? ""
            local.stationName = (v.count == 1 ? "Netatmo station" : "\(v.count) Netatmo stations") + place
        }
        var merged = local
        if let base, (base.distanceKm ?? 0) <= 10, abs(base.temperature - local.temperature) > tieBreakGap {
            merged.officialTemperature = base.temperature
            merged.officialStationName = base.stationName
            merged.officialDistanceKm = base.distanceKm
            merged.officialProvider = base.dataProvider
        }
        merged.condition = base?.condition
        merged.conditionText = base?.conditionText
        merged.skyStationName = base?.stationName
        merged.skyDataProvider = base?.dataProvider
        merged.skyDistanceKm = base?.distanceKm
        if let base, base.isLocal, base.windSpeed != nil {
            merged.windSpeed = base.windSpeed
            merged.windDirection = base.windDirection ?? merged.windDirection
            merged.windGusts = base.windGusts ?? merged.windGusts
        }
        return merged
    }
}

public extension Observation {
    /// Home stations report every ~10 minutes and wobble by a few tenths, so with only one or two
    /// of them the rounded "now" can flip 5° → 6° → 5° between refreshes. Averages this reading
    /// with the previous one for the same spot when that one is recent and close; a real change
    /// still comes through, at half speed for one refresh. Official stations are left alone.
    func smoothed(after previous: Observation?, now: Date = Date()) -> Observation {
        guard let previous, dataProvider == "NETATMO", previous.dataProvider == "NETATMO",
              now.timeIntervalSince(previous.observedAt) < Self.smoothingWindow,
              abs(temperature - previous.temperature) < Self.smoothingLimit else { return self }
        var o = self
        o.temperature = ((temperature + previous.temperature) / 2 * 10).rounded() / 10
        return o
    }

    /// Readings older than this aren't averaged in.
    static let smoothingWindow: TimeInterval = 45 * 60
    /// A bigger change than this is taken as real (a front, or a different set of stations).
    static let smoothingLimit: Double = 1.5
}
