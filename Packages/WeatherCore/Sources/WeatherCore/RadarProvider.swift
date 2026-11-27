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

    /// The mosaic's rain and snow layers can both light up for the same echo, and outside Canada
    /// the snow layer isn't split by temperature at all. Decide the type from the air temperature:
    /// snow at or below 1°C, rain at 3°C and above, and between the two keep what the radar says.
    public func typed(byTemperature celsius: Double?) -> RadarNow {
        guard let t = celsius, isPrecipitating else { return self }
        var r = self
        if t >= 3, isSnowing {
            // Roughly 1 cm of snow per 1 mm of water.
            r.rainMmPerHour = max(rainMmPerHour, snowCmPerHour)
            r.snowCmPerHour = 0
        } else if t <= 1, isRaining {
            r.snowCmPerHour = max(snowCmPerHour, rainMmPerHour)
            r.rainMmPerHour = 0
        } else if isSnowing, isRaining {
            r.snowCmPerHour = 0   // mixed near freezing: call it rain unless cold enough
        }
        return r
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
        async let rain = neighbourhood("RADAR_1KM_RRAI", at: coordinate)
        async let snow = neighbourhood("RADAR_1KM_RSNO", at: coordinate)
        let (r, s) = try await (rain, snow)
        guard let time = [r?.time, s?.time].compactMap({ $0 }).max(),
              Date().timeIntervalSince(time) < maxAge else { return nil }
        return RadarNow(rainMmPerHour: r?.value ?? 0, snowCmPerHour: s?.value ?? 0, time: time)
    }

    /// About 2 km apart: wider than one 1 km pixel, narrower than any real band of rain or snow.
    static let neighbourOffsetKm = 2.0

    /// The spot plus four points about 2 km north, south, east and west of it.
    static func neighbourhoodPoints(around c: Coordinate) -> [Coordinate] {
        let dLat = neighbourOffsetKm / 111.0
        let dLon = neighbourOffsetKm / (111.0 * max(0.2, cos(c.latitude * .pi / 180)))
        return [c,
                Coordinate(latitude: c.latitude + dLat, longitude: c.longitude),
                Coordinate(latitude: c.latitude - dLat, longitude: c.longitude),
                Coordinate(latitude: c.latitude, longitude: c.longitude + dLon),
                Coordinate(latitude: c.latitude, longitude: c.longitude - dLon)]
    }

    /// The median of the five points' readings. One bright pixel over the spot (ground clutter
    /// from a tower, a hill or the escarpment, which shows up most on cold, clear nights) is
    /// outvoted by its dry neighbours, while real rain or snow covers all five and still counts.
    static func median(_ values: [Double]) -> Double {
        let v = values.sorted()
        guard !v.isEmpty else { return 0 }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    private func neighbourhood(_ layer: String, at coordinate: Coordinate) async throws -> (value: Double, time: Date)? {
        let points = Self.neighbourhoodPoints(around: coordinate)
        let readings = try await withThrowingTaskGroup(of: (Int, (value: Double, time: Date)?).self) { group in
            for (i, p) in points.enumerated() {
                group.addTask {
                    // A neighbour that fails just drops out; only the spot itself must answer.
                    if i == 0 { return (i, try await self.sample(layer, at: p)) }
                    return (i, try? await self.sample(layer, at: p))
                }
            }
            var out: [Int: (value: Double, time: Date)] = [:]
            for try await (i, r) in group { if let r { out[i] = r } }
            return out
        }
        guard let centre = readings[0] else { return nil }
        // Only neighbours from the same frame vote.
        let sameFrame = readings.values.filter { abs($0.time.timeIntervalSince(centre.time)) < 60 }.map(\.value)
        guard sameFrame.count >= 3 else { return centre }
        return (Self.median(sameFrame), centre.time)
    }

    /// Environment Canada's mosaic covers Canada and the northern US.
    public static func covers(_ c: Coordinate) -> Bool {
        (35...75).contains(c.latitude) && (-145 ... -50).contains(c.longitude)
    }

    /// One layer's reading at one point: rain in mm/h (RADAR_1KM_RRAI) or snow in cm/h (RADAR_1KM_RSNO).
    public func reading(_ layer: String, at coordinate: Coordinate) async throws -> (value: Double, time: Date)? {
        try await sample(layer, at: coordinate)
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
    /// Radar rain lighter than this (mm/h) is overruled by dry local rain gauges.
    static let gaugeVetoRate: Double = 1.0

    /// Rain or snow that reaches the ground moistens the air it falls through within minutes, so a
    /// radar echo over air drier than this is falling apart aloft (virga) or isn't weather at all
    /// (26 Nov, 9:43 pm in Milton: "moderate rain" from the radar at 73% humidity, nothing falling).
    /// Below -2° the bar is lower, since snow can fall through air that is dry by the water scale.
    static func dryAirHumidity(at celsius: Double) -> Double { celsius > -2 ? 80 : 70 }

    /// False when the air here is too dry for the radar's echo to be reaching the ground.
    var radarEchoCanReachGround: Bool {
        guard let rh = current.humidity else { return true }
        return rh >= Self.dryAirHumidity(at: current.temperature)
    }

    /// When the radar shows rain or snow falling here now, say so even if the model or a
    /// distant station says cloudy. A dry radar changes nothing: it can miss very light snow.
    func applyingRadar(_ radar: RadarNow?) -> Forecast {
        let rawRadarRain = radar?.rainMmPerHour ?? 0
        guard let radar = radar?.typed(byTemperature: current.temperature) else { return self }
        if radar.isPrecipitating, !radarEchoCanReachGround { return self }
        // Virga guard: in dry surface air (RH < 80%), weak overhead radar (< 1.0 mm/h)
        // evaporates before reaching the ground; below 88% RH, ignore < 0.5 mm/h clutter.
        if current.temperature >= 3, (radar.rainMmPerHour < 0.5 || (rawRadarRain < 0.5)) {
            if radar.isPrecipitating { return self }
        }
        if let rh = current.humidity, radar.isRaining, !radar.isSnowing, current.temperature > 1,
           (observation?.rainLastHourMm ?? 0) < 0.1,
           (rh < 90 && radar.rainMmPerHour < 1.0) || radar.rainMmPerHour < 0.5 {
            return self
        }
        guard let condition = radar.condition else {
            // Dry radar overhead, yet "rain" from a station far away or the model: it isn't raining
            // here. Snow stays, as the radar can miss very light snow.
            guard current.temperature > 1, current.condition.isRainLike,
                  !(observation?.skyIsLocal ?? false) else { return self }
            var copy = self
            copy.current.condition = .overcast
            copy.observation?.conditionText = nil
            copy.skySource = "radar over this spot (dry)"
            return copy
        }
        // A light rain echo over dry rain gauges next door is rain aloft that isn't reaching the
        // ground. Snow and heavier rain still count.
        if observation?.gaugesSayDry == true, !radar.isSnowing, radar.rainMmPerHour < Self.gaugeVetoRate {
            return self
        }
        var copy = self
        copy.current.condition = condition
        copy.observation?.conditionText = radar.description
        copy.radar = radar
        copy.skySource = "radar over this spot"
        return copy
    }
}
