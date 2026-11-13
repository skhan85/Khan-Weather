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
    public static let defaultBaseURL = URL(string: "https://raspberrypi.tailf30d3.ts.net/v1/netatmo")!

    private let baseURL: URL
    private let loader: HTTPLoader
    /// Stations farther than this don't count as "here".
    let radiusKm: Double = 5
    let maxAge: TimeInterval = 3600

    public init(baseURL: URL = defaultBaseURL, loader: @escaping HTTPLoader = defaultLoader) {
        self.baseURL = baseURL
        self.loader = loader
    }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.4f", coordinate.latitude)),
                            URLQueryItem(name: "lon", value: String(format: "%.4f", coordinate.longitude))]
        var request = URLRequest(url: parts.url!, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ForecastError.httpStatus(http.statusCode) }
        return try Self.parse(data, near: coordinate, now: Date(), radiusKm: radiusKm, maxAge: maxAge)
    }

    /// Median of the (up to) three nearest fresh stations, so one sensor sitting in the sun
    /// or by a dryer vent can't skew "now".
    static func parse(_ data: Data, near c: Coordinate, now: Date, radiusKm: Double, maxAge: TimeInterval) throws -> Observation? {
        struct R: Decodable { let stations: [NetatmoStation] }
        let fresh = try JSONDecoder().decode(R.self, from: data).stations.compactMap { s -> (NetatmoStation, Double, Date)? in
            guard s.temperature != nil, let t = s.observed else { return nil }
            let time = Date(timeIntervalSince1970: t)
            let d = EnvironmentCanadaProvider.distanceKm(c, Coordinate(latitude: s.lat, longitude: s.lon))
            guard d <= radiusKm, now.timeIntervalSince(time) < maxAge else { return nil }
            return (s, d, time)
        }.sorted { $0.1 < $1.1 }
        let nearest = Array(fresh.prefix(3))
        guard let first = nearest.first else { return nil }

        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let v = values.sorted()
            return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        }
        let temperature = median(nearest.compactMap { $0.0.temperature })!
        let wind = fresh.first { $0.0.wind_strength != nil }?.0
        let name = nearest.count == 1 ? "Netatmo station" : "\(nearest.count) Netatmo stations"
        var o = Observation(stationName: name + (first.0.city.map { " in \($0)" } ?? ""),
                            observedAt: nearest.map(\.2).min() ?? first.2,
                            temperature: (temperature * 10).rounded() / 10,
                            humidity: median(nearest.compactMap { $0.0.humidity }),
                            windSpeed: wind?.wind_strength, windDirection: wind?.wind_angle,
                            distanceKm: first.1)
        o.dataProvider = "NETATMO"
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
        async let b = try? netatmo.observation(near: coordinate)
        let base = await a ?? nil
        guard let local = await b ?? nil else { return base }
        return Self.merge(official: base, netatmo: local)
    }

    static func merge(official base: Observation?, netatmo local: Observation) -> Observation {
        var merged = local
        merged.condition = base?.condition
        merged.conditionText = base?.conditionText
        merged.skyStationName = base?.stationName
        merged.skyDataProvider = base?.dataProvider
        if merged.windSpeed == nil, let base, base.isLocal {
            merged.windSpeed = base.windSpeed
            merged.windDirection = base.windDirection
        }
        return merged
    }
}
