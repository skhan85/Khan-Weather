import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The usual daily high and low for each day of the year at one spot: the 1991–2020 average from
/// Open-Meteo's historical archive (ERA5 reanalysis), smoothed over two weeks so one odd year
/// doesn't make a single date stand out. Only a yardstick for "warmer than usual"; no forecast
/// temperature uses it.
public struct ClimateNormals: Equatable, Codable, Sendable {
    public var location: Coordinate
    /// °C, 365 values, 1 January first (29 February uses 28 February).
    public var highs: [Double]
    public var lows: [Double]

    public init(location: Coordinate, highs: [Double], lows: [Double]) {
        self.location = location
        self.highs = highs
        self.lows = lows
    }

    /// Day of a non-leap year, 0–364.
    static func dayIndex(month: Int, day: Int) -> Int {
        let starts = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        let m = min(max(month, 1), 12)
        return starts[m - 1] + min(day, m == 2 ? 28 : 31) - 1
    }

    /// The normal high and low for `date`'s calendar day in `timeZone`.
    public func normal(for date: Date, timeZone: TimeZone) -> (high: Double, low: Double)? {
        guard highs.count == 365, lows.count == 365 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.month, .day], from: date)
        guard let month = c.month, let day = c.day else { return nil }
        let i = Self.dayIndex(month: month, day: day)
        return (highs[i], lows[i])
    }

    /// True when these normals are for (about) the same spot as `c`, within ~10 km.
    public func covers(_ c: Coordinate) -> Bool {
        abs(location.latitude - c.latitude) < 0.1 && abs(location.longitude - c.longitude) < 0.13
    }

    /// Averages daily highs and lows ("YYYY-MM-DD" dates) by day of year, then smooths each day
    /// with the 7 days either side.
    public static func compute(location: Coordinate, dates: [String], highs: [Double?], lows: [Double?]) -> ClimateNormals? {
        var hiSum = [Double](repeating: 0, count: 365), hiN = [Int](repeating: 0, count: 365)
        var loSum = [Double](repeating: 0, count: 365), loN = [Int](repeating: 0, count: 365)
        for (k, d) in dates.enumerated() {
            let parts = d.split(separator: "-")
            guard parts.count == 3, let m = Int(parts[1]), let day = Int(parts[2]) else { continue }
            let i = dayIndex(month: m, day: day)
            if k < highs.count, let h = highs[k] { hiSum[i] += h; hiN[i] += 1 }
            if k < lows.count, let l = lows[k] { loSum[i] += l; loN[i] += 1 }
        }
        guard hiN.allSatisfy({ $0 > 0 }), loN.allSatisfy({ $0 > 0 }) else { return nil }
        func smooth(_ sum: [Double], _ n: [Int]) -> [Double] {
            (0..<365).map { i in
                var s = 0.0, c = 0
                for j in -7...7 {
                    let k = (i + j + 365) % 365
                    s += sum[k]; c += n[k]
                }
                return s / Double(c)
            }
        }
        return ClimateNormals(location: location, highs: smooth(hiSum, hiN), lows: smooth(loSum, loN))
    }
}

/// How a day compares with the normal, for the Now card and the daily arrows.
public enum NormalComparison {
    /// Smaller differences than this (°C) count as "about usual", so a degree of bias in the
    /// normal can never flip warmer to colder.
    public static let threshold: Double = 2

    /// +1 warmer, -1 colder, 0 about usual.
    public static func trend(high: Double, normalHigh: Double) -> Int {
        let d = high - normalHigh
        if d >= threshold { return 1 }
        if d <= -threshold { return -1 }
        return 0
    }

    /// "6° warmer than usual" / "About usual for the date", then the normal high.
    public static func text(high: Double, normalHigh: Double,
                            unit: TemperatureUnit = UnitSettings.current.temperature) -> String {
        let normal = "normal high \(WeatherFormat.temperature(normalHigh, unit: unit))"
        let d = high - normalHigh
        let shown = Int((abs(d) * (unit == .fahrenheit ? 1.8 : 1)).rounded())
        switch trend(high: high, normalHigh: normalHigh) {
        case 1: return "\(shown)° warmer than usual · \(normal)"
        case -1: return "\(shown)° colder than usual · \(normal)"
        default: return "About usual for the date · \(normal)"
        }
    }
}

/// Fetches 1991–2020 daily highs and lows from Open-Meteo's archive and turns them into normals.
/// Normals never change, so each spot (rounded to ~5 km) is fetched once and kept on disk.
public struct ClimateNormalsProvider: Sendable {
    public typealias DataLoader = OpenMeteoProvider.DataLoader
    private let loader: DataLoader
    private let directory: URL?

    public init(loader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) },
                directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        self.loader = loader
        self.directory = directory
    }

    static func spot(_ c: Coordinate) -> Coordinate {
        Coordinate(latitude: (c.latitude * 20).rounded() / 20, longitude: (c.longitude * 20).rounded() / 20)
    }

    private func cacheURL(_ s: Coordinate) -> URL? {
        directory?.appendingPathComponent(String(format: "normals-%.2f,%.2f.json", s.latitude, s.longitude))
    }

    public func normals(at c: Coordinate) async throws -> ClimateNormals {
        let s = Self.spot(c)
        if let url = cacheURL(s), let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(ClimateNormals.self, from: data) {
            return saved
        }
        var comps = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", s.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", s.longitude)),
            URLQueryItem(name: "start_date", value: "1991-01-01"),
            URLQueryItem(name: "end_date", value: "2020-12-31"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 60
        let (data, response) = try await loader(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ForecastError.httpStatus(http.statusCode)
        }
        let normals = try Self.parse(data, location: s)
        if let url = cacheURL(s), let out = try? JSONEncoder().encode(normals) {
            try? out.write(to: url, options: .atomic)
        }
        return normals
    }

    static func parse(_ data: Data, location: Coordinate) throws -> ClimateNormals {
        struct Response: Decodable {
            struct Daily: Decodable {
                let time: [String]
                let temperature_2m_max: [Double?]
                let temperature_2m_min: [Double?]
            }
            let daily: Daily
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let n = ClimateNormals.compute(location: location, dates: r.daily.time,
                                             highs: r.daily.temperature_2m_max, lows: r.daily.temperature_2m_min)
        else { throw ForecastError.missingData("daily normals") }
        return n
    }
}
