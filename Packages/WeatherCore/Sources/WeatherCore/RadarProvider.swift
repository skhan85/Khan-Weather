import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the radar sees over one point right now.
public struct RadarNow: Equatable, Codable, Sendable {
    /// Rain rate, mm/h.
    public var rainMmPerHour: Double
    /// Snow rate, cm/h.
    public var snowCmPerHour: Double
    /// Time of the radar frame.
    public var time: Date

    public init(rainMmPerHour: Double, snowCmPerHour: Double, time: Date) {
        self.rainMmPerHour = rainMmPerHour
        self.snowCmPerHour = snowCmPerHour
        self.time = time
    }

    /// Below these the radar is reading noise.
    static let rainThreshold: Double = 0.1
    static let snowThreshold: Double = 0.05

    public var isSnowing: Bool { snowCmPerHour >= Self.snowThreshold }
    public var isRaining: Bool { rainMmPerHour >= Self.rainThreshold }
    public var isPrecipitating: Bool { isSnowing || isRaining }

    /// Snow wins when both show, as the radar splits mixed precipitation by temperature.
    public var condition: WeatherCondition? {
        if isSnowing { return .snow }
        if isRaining { return rainMmPerHour < 0.5 ? .drizzle : .rain }
        return nil
    }

    /// "Light snow", "Moderate rain", using Environment Canada's rate bands.
    public var description: String? {
        if isSnowing {
            let s = snowCmPerHour
            return (s < 0.5 ? "Light" : s < 1 ? "Moderate" : "Heavy") + " snow"
        }
        if isRaining {
            let r = rainMmPerHour
            return (r < 2.5 ? "Light" : r < 7.6 ? "Moderate" : "Heavy") + " rain"
        }
        return nil
    }
}

/// Environment Canada's North American 1 km radar mosaic (MSC GeoMet WMS, Open Government Licence).
/// Covers Canada and the US; elsewhere it returns nothing useful and is ignored.
public struct ECCCRadarProvider: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let loader: DataLoader
    /// Older frames are ignored; GeoMet publishes every 6 minutes.
    let maxAge: TimeInterval = 30 * 60

    public init(loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }) {
        self.loader = loader
    }

    public func now(at coordinate: Coordinate) async throws -> RadarNow? {
        async let rain = sample("RADAR_1KM_RRAI", at: coordinate)
        async let snow = sample("RADAR_1KM_RSNO", at: coordinate)
        let (r, s) = try await (rain, snow)
        guard let time = [r?.time, s?.time].compactMap({ $0 }).max(),
              Date().timeIntervalSince(time) < maxAge else { return nil }
        return RadarNow(rainMmPerHour: r?.value ?? 0, snowCmPerHour: s?.value ?? 0, time: time)
    }

    private func sample(_ layer: String, at coordinate: Coordinate) async throws -> (value: Double, time: Date)? {
        let (data, response) = try await loader(URLRequest(url: Self.url(layer: layer, at: coordinate), timeoutInterval: 15))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return try Self.parse(data)
    }

    static func url(layer: String, at coordinate: Coordinate) -> URL {
        let c = coordinate.rounded
        let d = 0.01
        // WMS 1.3.0 with EPSG:4326 takes the box as lat,lon order. The 3x3 image's middle pixel is the point.
        let bbox = [c.latitude - d, c.longitude - d, c.latitude + d, c.longitude + d]
            .map { String(format: "%.4f", $0) }.joined(separator: ",")
        var comps = URLComponents(string: "https://geo.weather.gc.ca/geomet")!
        comps.queryItems = [
            URLQueryItem(name: "service", value: "WMS"),
            URLQueryItem(name: "version", value: "1.3.0"),
            URLQueryItem(name: "request", value: "GetFeatureInfo"),
            URLQueryItem(name: "layers", value: layer),
            URLQueryItem(name: "query_layers", value: layer),
            URLQueryItem(name: "crs", value: "EPSG:4326"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "width", value: "3"),
            URLQueryItem(name: "height", value: "3"),
            URLQueryItem(name: "i", value: "1"),
            URLQueryItem(name: "j", value: "1"),
            URLQueryItem(name: "info_format", value: "application/json"),
        ]
        return comps.url!
    }

    static func parse(_ data: Data) throws -> (value: Double, time: Date)? {
        struct Collection: Decodable { let features: [Feature] }
        struct Feature: Decodable { let properties: Properties }
        struct Properties: Decodable {
            let value: Double?
            let time: String?
        }
        guard let p = try JSONDecoder().decode(Collection.self, from: data).features.first?.properties,
              let time = p.time.flatMap(EnvironmentCanadaProvider.parseDate) else { return nil }
        return (p.value ?? 0, time)
    }
}

public extension Forecast {
    /// When the radar shows rain or snow falling here now, say so even if the model or a
    /// distant station says cloudy. A dry radar changes nothing: it can miss very light snow.
    func applyingRadar(_ radar: RadarNow?) -> Forecast {
        guard let radar, let condition = radar.condition else { return self }
        var copy = self
        copy.current.condition = condition
        copy.observation?.conditionText = radar.description
        copy.radar = radar
        return copy
    }
}
