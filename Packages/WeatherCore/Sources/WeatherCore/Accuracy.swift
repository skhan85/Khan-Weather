import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Each model's next-day high and low, written down the day before, then checked against
/// what Environment Canada's nearest climate station recorded.
public struct AccuracyLog: Codable, Equatable, Sendable {
    public struct Forecast: Codable, Equatable, Sendable {
        public var day: String                 // "2026-11-15", local to the place
        public var highs: [String: Double]     // WeatherModel raw value -> °C
        public var lows: [String: Double]
        public init(day: String, highs: [String: Double], lows: [String: Double]) {
            self.day = day; self.highs = highs; self.lows = lows
        }
    }
    public struct Observed: Codable, Equatable, Sendable {
        public var day: String
        public var high: Double
        public var low: Double
        public var station: String
        public init(day: String, high: Double, low: Double, station: String) {
            self.day = day; self.high = high; self.low = low; self.station = station
        }
    }
    public struct Score: Equatable, Sendable, Identifiable {
        public var model: WeatherModel
        public var days: Int
        public var highError: Double            // mean absolute error, °C
        public var lowError: Double
        public var overall: Double { (highError + lowError) / 2 }
        public var id: String { model.rawValue }
    }

    public var forecasts: [Forecast] = []
    public var observed: [Observed] = []
    public init() {}

    public static let keepDays = 45

    public mutating func record(_ f: Forecast) {
        guard !forecasts.contains(where: { $0.day == f.day }) else { return }   // keep the day-before forecast
        forecasts.append(f)
        forecasts = Array(forecasts.suffix(Self.keepDays))
    }

    public mutating func record(_ o: Observed) {
        observed.removeAll { $0.day == o.day }
        observed.append(o)
        observed = Array(observed.suffix(Self.keepDays))
    }

    /// Days that have a forecast but no observation yet, oldest first, excluding `today` and later.
    public func unscoredDays(before today: String) -> [String] {
        let seen = Set(observed.map(\.day))
        return forecasts.map(\.day).filter { $0 < today && !seen.contains($0) }.sorted()
    }

    /// Mean absolute error per model over the scored days, best first.
    public func scores() -> [Score] {
        let truth = Dictionary(observed.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        var out: [Score] = []
        for model in WeatherModel.allCases {
            var hi: [Double] = [], lo: [Double] = []
            for f in forecasts {
                guard let o = truth[f.day] else { continue }
                if let h = f.highs[model.rawValue] { hi.append(abs(h - o.high)) }
                if let l = f.lows[model.rawValue] { lo.append(abs(l - o.low)) }
            }
            let n = min(hi.count, lo.count)
            guard n > 0 else { continue }
            out.append(Score(model: model, days: n,
                             highError: hi.reduce(0, +) / Double(hi.count),
                             lowError: lo.reduce(0, +) / Double(lo.count)))
        }
        return out.sorted { $0.overall < $1.overall }
    }

    /// `date` (plus `offsetDays`) in `timeZone`, as "yyyy-MM-dd".
    public static func dayString(_ date: Date, timeZone: TimeZone, offsetDays: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shifted = calendar.date(byAdding: .day, value: offsetDays, to: date) ?? date
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// A day's recorded high and low from Environment Canada's climate stations
/// (https://api.weather.gc.ca, collection `climate-daily`). Canada only.
public struct ClimateDailyProvider: Sendable {
    private let loader: HTTPLoader
    public init(loader: @escaping HTTPLoader = defaultLoader) { self.loader = loader }

    public func observed(day: String, near coordinate: Coordinate) async throws -> AccuracyLog.Observed? {
        guard EnvironmentCanadaProvider.mightBeInCanada(coordinate) else { return nil }
        let span = 0.35
        let bbox = [coordinate.longitude - span * 1.4, coordinate.latitude - span,
                    coordinate.longitude + span * 1.4, coordinate.latitude + span]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
        var parts = URLComponents(string: "https://api.weather.gc.ca/collections/climate-daily/items")!
        parts.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "datetime", value: day),
            URLQueryItem(name: "limit", value: "50"),
        ]
        return try Self.parse(try await fetch(parts.url!, loader: loader), day: day, near: coordinate)
    }

    /// The nearest station that recorded both a high and a low on `day`.
    static func parse(_ data: Data, day: String, near coordinate: Coordinate) throws -> AccuracyLog.Observed? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw ForecastError.missingData("features") }
        var best: (distance: Double, observed: AccuracyLog.Observed)?
        for feature in features {
            guard let p = feature["properties"] as? [String: Any],
                  let date = p["LOCAL_DATE"] as? String, date.hasPrefix(day),
                  let high = (p["MAX_TEMPERATURE"] as? NSNumber)?.doubleValue,
                  let low = (p["MIN_TEMPERATURE"] as? NSNumber)?.doubleValue,
                  let point = EnvironmentCanadaProvider.pointCoordinate(feature["geometry"]) else { continue }
            let distance = EnvironmentCanadaProvider.distanceKm(coordinate, point)
            guard distance < (best?.distance ?? .infinity) else { continue }
            let name = (p["STATION_NAME"] as? String) ?? "Climate station"
            best = (distance, AccuracyLog.Observed(day: day, high: high, low: low, station: name.capitalized))
        }
        return best?.observed
    }
}
