import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// "A storm is heading for you": a heavy radar echo upwind of one spot, moving towards it with the
/// wind that steers storms (about 3 km up, the 700 hPa level), and when it should arrive.
///
/// Only the person's own spot counts. The scan looks along a narrow corridor upwind of it, so a
/// storm passing 20 km to the side never fires. Kept free of any app code so other platforms can
/// port it as is.
public struct StormHeadsUp: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case thunderstorm, heavyRain, snowSquall
    }

    public enum Source: String, Sendable {
        /// Seen on radar upwind.
        case radar
        /// Forecast thunder at this spot, nothing on radar yet (or no radar here).
        case forecast
    }

    public var kind: Kind
    public var source: Source
    /// When it should reach the spot.
    public var arrival: Date
    /// How far away the leading edge is now, km (radar only).
    public var distanceKm: Double?
    /// Bearing from the spot to the storm, degrees (radar only).
    public var bearing: Double?
    /// How fast it is moving, km/h (radar only).
    public var speedKmh: Double?

    public init(kind: Kind, source: Source, arrival: Date, distanceKm: Double? = nil,
                bearing: Double? = nil, speedKmh: Double? = nil) {
        self.kind = kind
        self.source = source
        self.arrival = arrival
        self.distanceKm = distanceKm
        self.bearing = bearing
        self.speedKmh = speedKmh
    }

    public var title: String {
        switch (kind, source) {
        case (.thunderstorm, .forecast): return "Thunderstorms possible"
        case (.thunderstorm, .radar): return "Thunderstorm heading your way"
        case (.heavyRain, _): return "Heavy rain heading your way"
        case (.snowSquall, _): return "Snow squall heading your way"
        }
    }

    private var noun: String {
        switch kind {
        case .thunderstorm: return "A thunderstorm"
        case .heavyRain: return "Heavy rain"
        case .snowSquall: return "A snow squall"
        }
    }

    /// "Heavy rain about 25 km west of you, moving east at 40 km/h. Likely here around 4:10 PM."
    public func body(at now: Date = Date(), timeZone: TimeZone,
                     distance: (Double) -> String = { "\(Int(($0 / 5).rounded() * 5)) km" },
                     speed: (Double) -> String = { "\(Int(($0 / 5).rounded() * 5)) km/h" }) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        let when = f.string(from: arrival)
        guard source == .radar, let distanceKm, let bearing else {
            return "Forecast models show thunderstorms here around \(when). Open the radar for the latest."
        }
        var text = "\(noun) about \(distance(max(5, distanceKm))) \(StormWatch.compassWord(bearing)) of you"
        if let speedKmh {
            text += ", moving \(StormWatch.compassWord(bearing + 180)) at \(speed(speedKmh))"
        }
        let minutes = Int(arrival.timeIntervalSince(now) / 60)
        text += minutes <= 20 ? ". Likely here within 20 minutes." : ". Likely here around \(when)."
        return text
    }

    /// One line for the radar card: "Heavy rain 25 km west, here around 4:10 PM".
    public func shortText(timeZone: TimeZone, distance: (Double) -> String = { "\(Int(($0 / 5).rounded() * 5)) km" }) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        guard source == .radar, let distanceKm, let bearing else {
            return "Thunderstorms possible around \(f.string(from: arrival))"
        }
        let what: String
        switch kind {
        case .thunderstorm: what = "Thunderstorm"
        case .heavyRain: what = "Heavy rain"
        case .snowSquall: what = "Snow squall"
        }
        return "\(what) \(distance(max(5, distanceKm))) \(StormWatch.compassWord(bearing)), here around \(f.string(from: arrival))"
    }
}

/// The wind that carries storms, and what the forecast says about the next few hours.
public struct StormContext: Equatable, Sendable {
    /// 700 hPa wind speed, km/h.
    public var steeringSpeed: Double?
    /// Direction the 700 hPa wind comes from, degrees.
    public var steeringFrom: Double?
    /// Most unstable air in the next 3 hours (convective available potential energy), J/kg.
    public var cape: Double?
    /// First hour in the next 3 with thunder in the forecast here.
    public var thunderAt: Date?
    /// Highest chance of rain or snow in the next 3 hours, percent.
    public var maxChance: Double?
    /// Air temperature now, °C, to pick the rain or snow radar.
    public var temperature: Double?

    public init(steeringSpeed: Double? = nil, steeringFrom: Double? = nil, cape: Double? = nil,
                thunderAt: Date? = nil, maxChance: Double? = nil, temperature: Double? = nil) {
        self.steeringSpeed = steeringSpeed
        self.steeringFrom = steeringFrom
        self.cape = cape
        self.thunderAt = thunderAt
        self.maxChance = maxChance
        self.temperature = temperature
    }

    /// Worth spending a radar scan on: thunder or unstable air forecast, or a fair chance of rain or snow.
    public var worthScanning: Bool {
        thunderAt != nil || (cape ?? 0) >= StormWatch.scanCape || (maxChance ?? 0) >= 30
    }
}

/// One radar reading in the scan.
public struct StormSample: Equatable, Sendable {
    /// km upwind of the spot, along the storm's track.
    public var alongKm: Double
    /// km to the side of the track (negative: left of it).
    public var acrossKm: Double
    public var coordinate: Coordinate
    /// mm/h.
    public var rain: Double
    /// cm/h.
    public var snow: Double

    public init(alongKm: Double, acrossKm: Double, coordinate: Coordinate, rain: Double, snow: Double) {
        self.alongKm = alongKm
        self.acrossKm = acrossKm
        self.coordinate = coordinate
        self.rain = rain
        self.snow = snow
    }
}

public enum StormWatch {
    /// Rain this heavy (mm/h) is a downpour; about 40 dBZ on radar.
    public static let heavyRain = 10.0
    /// Snow this heavy (cm/h) is a squall: whiteouts on the road.
    public static let squallSnow = 2.0
    /// With this much unstable air (J/kg), a downpour is most likely a thunderstorm.
    public static let thunderCape = 300.0
    /// Below this, and with no thunder or rain forecast, skip the radar scan.
    static let scanCape = 200.0
    /// Storms steered slower than this are treated as this, so a slow storm doesn't look hours off.
    static let minSpeed = 15.0
    /// Only storms arriving within this many minutes are worth a heads-up.
    public static let lookAhead: TimeInterval = 75 * 60
    /// One storm heads-up per this many hours.
    public static let quietPeriod: TimeInterval = 3 * 3600
    /// The scan's corridor: distances upwind (km) and offsets to each side (km).
    static let along: [Double] = [8, 16, 26, 38, 52]
    static let across: [Double] = [-6, 0, 6]

    /// The points to read on radar: a corridor 12 km wide reaching about 50 km upwind.
    /// Nil without a steering wind, as there's no way to tell where storms come from.
    public static func scanPoints(around spot: Coordinate, context: StormContext) -> [(alongKm: Double, acrossKm: Double, coordinate: Coordinate)]? {
        guard let from = context.steeringFrom else { return nil }
        var points: [(alongKm: Double, acrossKm: Double, coordinate: Coordinate)] = []
        for a in along {
            for x in across {
                // Upwind is the direction the wind comes from; sideways is 90° off it.
                let upwind = destination(from: spot, bearing: from, km: a)
                points.append((a, x, x == 0 ? upwind : destination(from: upwind, bearing: from + (x > 0 ? 90 : -90), km: abs(x))))
            }
        }
        return points
    }

    /// What's coming, if anything. `samples` are the radar readings along the corridor (empty when
    /// there's no radar here); `overhead` is the radar right over the spot.
    public static func assess(samples: [StormSample], overhead: RadarNow?, context: StormContext,
                              now: Date = Date()) -> StormHeadsUp? {
        // Already pouring here: it isn't "on the way" any more.
        if let overhead, overhead.rainMmPerHour >= heavyRain || overhead.snowCmPerHour >= squallSnow { return nil }
        let unstable = context.thunderAt != nil || (context.cape ?? 0) >= thunderCape
        let speed = max(context.steeringSpeed ?? 0, minSpeed)

        let hits = samples.filter { $0.rain >= heavyRain || $0.snow >= squallSnow }
        if let nearest = hits.min(by: { $0.alongKm < $1.alongKm }), let from = context.steeringFrom {
            let travel = nearest.alongKm / speed * 3600
            guard travel <= lookAhead else { return nil }
            // A squall is snow, unless it's plainly too warm for snow.
            let snowy = nearest.snow >= squallSnow && (context.temperature ?? 0) <= 2
            let kind: StormHeadsUp.Kind = snowy ? .snowSquall : unstable ? .thunderstorm : .heavyRain
            return StormHeadsUp(kind: kind, source: .radar, arrival: now.addingTimeInterval(travel),
                                distanceKm: nearest.alongKm, bearing: from, speedKmh: context.steeringSpeed)
        }

        // Nothing on radar upwind (or no radar here): thunder in the forecast for this spot within
        // the hour or so, in properly unstable air.
        if let thunder = context.thunderAt, thunder.timeIntervalSince(now) <= lookAhead,
           (context.cape ?? thunderCape) >= thunderCape, samples.isEmpty || context.steeringFrom == nil {
            return StormHeadsUp(kind: .thunderstorm, source: .forecast, arrival: max(thunder, now))
        }
        return nil
    }

    /// Whether to send it: not when one went out in the last few hours.
    public static func shouldNotify(_ storm: StormHeadsUp?, lastNotified: Date?, now: Date = Date()) -> StormHeadsUp? {
        guard let storm else { return nil }
        if let lastNotified, now.timeIntervalSince(lastNotified) < quietPeriod { return nil }
        return storm
    }

    /// "west", "north-east".
    public static func compassWord(_ degrees: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d / 45).rounded()) % 8]
    }

    /// The point `km` away from `from` in direction `bearing` (great circle).
    public static func destination(from: Coordinate, bearing: Double, km: Double) -> Coordinate {
        let r = 6371.0
        let d = km / r
        let b = bearing * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lon1 = from.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        let lon2 = lon1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return Coordinate(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}

/// Fetches what StormWatch needs: the steering wind and instability from Open-Meteo, then the
/// Environment Canada radar along the corridor. A handful of small requests, and the radar scan
/// only runs when the forecast gives a reason to look.
public struct StormWatchProvider: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let loader: DataLoader

    public init(loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }) {
        self.loader = loader
    }

    public func check(at spot: Coordinate, now: Date = Date()) async -> StormHeadsUp? {
        guard let context = try? await context(at: spot, now: now) else { return nil }
        guard context.worthScanning else { return nil }
        guard ECCCRadarProvider.covers(spot), let points = StormWatch.scanPoints(around: spot, context: context) else {
            return StormWatch.assess(samples: [], overhead: nil, context: context, now: now)
        }
        let radar = ECCCRadarProvider(loader: loader)
        // Pick the radar layer by temperature: rain when warm, snow when cold, both in between.
        let t = context.temperature ?? 5
        let layers = t > 2 ? ["RADAR_1KM_RRAI"] : t < -1 ? ["RADAR_1KM_RSNO"] : ["RADAR_1KM_RRAI", "RADAR_1KM_RSNO"]
        let overhead = try? await radar.now(at: spot)
        let samples = await withTaskGroup(of: StormSample?.self) { group in
            for p in points {
                group.addTask {
                    var rain = 0.0, snow = 0.0, read = false
                    for layer in layers {
                        guard let s = try? await radar.reading(layer, at: p.coordinate),
                              now.timeIntervalSince(s.time) < 30 * 60 else { continue }
                        read = true
                        if layer.hasSuffix("RRAI") { rain = s.value } else { snow = s.value }
                    }
                    // A point the radar couldn't be read at says nothing, rather than "dry".
                    guard read else { return nil }
                    return StormSample(alongKm: p.alongKm, acrossKm: p.acrossKm, coordinate: p.coordinate, rain: rain, snow: snow)
                }
            }
            var all: [StormSample] = []
            for await s in group { if let s { all.append(s) } }
            return all
        }
        return StormWatch.assess(samples: samples, overhead: overhead, context: context, now: now)
    }

    func context(at spot: Coordinate, now: Date) async throws -> StormContext {
        let (data, response) = try await loader(URLRequest(url: Self.url(spot), timeoutInterval: 20))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ForecastError.httpStatus(http.statusCode)
        }
        return try Self.parse(data, now: now)
    }

    static func url(_ c: Coordinate) -> URL {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", c.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,cape,wind_speed_700hPa,wind_direction_700hPa"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "past_hours", value: "1"),
            URLQueryItem(name: "forecast_hours", value: "4"),
        ]
        return comps.url!
    }

    /// Reads the hours from the current one through three hours ahead.
    static func parse(_ data: Data, now: Date) throws -> StormContext {
        struct Response: Decodable {
            struct Hourly: Decodable {
                let time: [Double]
                let temperature_2m: [Double?]?
                let precipitation_probability: [Double?]?
                let weather_code: [Double?]?
                let cape: [Double?]?
                let wind_speed_700hPa: [Double?]?
                let wind_direction_700hPa: [Double?]?
            }
            let hourly: Hourly
        }
        let h = try JSONDecoder().decode(Response.self, from: data).hourly
        let t = now.timeIntervalSince1970
        let window = h.time.indices.filter { h.time[$0] + 3600 > t && h.time[$0] <= t + 3 * 3600 }
        func values(_ a: [Double?]?) -> [Double] { window.compactMap { i in a.flatMap { i < $0.count ? $0[i] : nil } } }

        // Average the steering wind over the next two hours as a vector, so 350° and 10° make north.
        var u = 0.0, v = 0.0, n = 0.0
        for i in window.prefix(3) {
            guard let s = h.wind_speed_700hPa?[safe: i] ?? nil, let d = h.wind_direction_700hPa?[safe: i] ?? nil else { continue }
            u += s * sin(d * .pi / 180)
            v += s * cos(d * .pi / 180)
            n += 1
        }
        var speed: Double?, from: Double?
        if n > 0 {
            u /= n; v /= n
            speed = (u * u + v * v).squareRoot()
            from = (atan2(u, v) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
        let thunder = window.first { i in
            guard let code = h.weather_code?[safe: i] ?? nil else { return false }
            return code >= 95
        }.map { Date(timeIntervalSince1970: h.time[$0]) }
        let temperature = window.first.flatMap { h.temperature_2m?[safe: $0] ?? nil }
        return StormContext(steeringSpeed: speed, steeringFrom: from,
                            cape: values(h.cape).max(), thunderAt: thunder,
                            maxChance: values(h.precipitation_probability).max(), temperature: temperature)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
