import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What someone standing outside says the sky is doing. 27 Nov, 7:48 pm in Mississauga the card
/// said "Overcast" while it drizzled: radar beams pass over drizzle, and stations are kilometres
/// away. A person at the spot is the best sensor there is, so a fresh report beats every guess.
public enum ReportKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case clear, partlyCloudy, cloudy, fog
    case drizzle, rain, heavyRain, thunderstorm
    case snow, rainAndSnow, freezingRain

    public var id: String { rawValue }

    /// Button label: what the person sees outside.
    public func label(isDay: Bool = true) -> String {
        switch self {
        case .clear: return isDay ? "Sunny" : "Clear"
        case .partlyCloudy: return "Some clouds"
        case .cloudy: return "Cloudy"
        case .fog: return "Foggy"
        case .drizzle: return "Drizzle"
        case .rain: return "Raining"
        case .heavyRain: return "Pouring"
        case .thunderstorm: return "Thunder"
        case .snow: return "Snowing"
        case .rainAndSnow: return "Rain and snow"
        case .freezingRain: return "Freezing rain"
        }
    }

    public var condition: WeatherCondition {
        switch self {
        case .clear: return .clear
        case .partlyCloudy: return .partlyCloudy
        case .cloudy: return .overcast
        case .fog: return .fog
        case .drizzle: return .drizzle
        case .rain, .heavyRain: return .rain
        case .thunderstorm: return .thunderstorm
        case .snow: return .snow
        case .rainAndSnow: return .rain
        case .freezingRain: return .freezingRain
        }
    }

    /// The Now card's words for it.
    public var conditionText: String {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly cloudy"
        case .cloudy: return "Cloudy"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy rain"
        case .thunderstorm: return "Thunderstorm"
        case .snow: return "Snow"
        case .rainAndSnow: return "Rain and snow"
        case .freezingRain: return "Freezing rain"
        }
    }

    /// Something is falling (or a storm): the learner counts these hours as wet.
    public var isWet: Bool {
        switch self {
        case .clear, .partlyCloudy, .cloudy, .fog: return false
        default: return true
        }
    }

    /// The current 15-minute slot, so Next 2 hours agrees with the card: rain in mm and snow in
    /// cm per 15 minutes, picked to land in the chart's band for that word (drizzle under 0.5 mm/h,
    /// light rain, heavy rain from 7.6 mm/h, light snow).
    var slot: (rain: Double, snow: Double) {
        switch self {
        case .clear, .partlyCloudy, .cloudy, .fog: return (0, 0)
        case .drizzle: return (0.1, 0)
        case .rain: return (0.4, 0)
        case .heavyRain: return (2.5, 0)
        case .thunderstorm: return (1.5, 0)
        case .snow: return (0, 0.12)
        case .rainAndSnow: return (0.15, 0.15)
        case .freezingRain: return (0.3, 0)
        }
    }

    /// The order the buttons appear in: dry first, then rain, then winter.
    public static let shown: [ReportKind] = [.clear, .partlyCloudy, .cloudy, .fog,
                                              .drizzle, .rain, .heavyRain, .thunderstorm,
                                              .snow, .rainAndSnow, .freezingRain]
}

/// One report: what, when and where. `id` lets the app tell its own reports in the relay's list.
public struct ConditionReport: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ReportKind
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    /// True for a report made on this phone.
    public var mine: Bool

    public init(id: String = UUID().uuidString, kind: ReportKind, time: Date = Date(),
                at c: Coordinate, mine: Bool = true) {
        self.id = id
        self.kind = kind
        self.time = time
        self.latitude = c.latitude
        self.longitude = c.longitude
        self.mine = mine
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    /// A report holds for 45 minutes within 8 km of where it was made, whoever made it: the
    /// widget gets this phone's reports back from the relay without knowing they're its own, so
    /// one rule keeps the widget and the app saying the same.
    public static let maxAge: TimeInterval = 45 * 60
    public static let maxKm: Double = 8

    public func applies(at c: Coordinate, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(time)
        return age >= -300 && age <= Self.maxAge && EnvironmentCanadaProvider.distanceKm(coordinate, c) <= Self.maxKm
    }
}

public extension Forecast {
    /// The newest report that holds here, or nil.
    func activeReport(_ reports: [ConditionReport], now: Date = Date()) -> ConditionReport? {
        reports.filter { $0.applies(at: location, now: now) }.max { $0.time < $1.time }
    }

    /// Runs last, after radar and the nowcast: a fresh report from someone at the spot sets the
    /// sky, the Now card's words, the first hour (via `current`) and the current 15-minute slot of
    /// Next 2 hours, so every screen and the widget say the same. Temperature is untouched.
    func applyingReports(_ reports: [ConditionReport], now: Date = Date()) -> Forecast {
        guard let report = activeReport(reports, now: now) else { return self }
        var copy = self
        copy.current.condition = report.kind.condition
        copy.observation?.conditionText = report.kind.conditionText
        if !report.kind.isWet || report.kind == .thunderstorm { copy.radar = nil }
        let minutes = max(0, Int((now.timeIntervalSince(report.time) / 60).rounded()))
        let ago = minutes < 1 ? "just now" : "\(minutes) min ago"
        if report.mine {
            copy.skySource = "your report, \(ago)"
        } else {
            let km = EnvironmentCanadaProvider.distanceKm(report.coordinate, location)
            let away = km < 1 ? "nearby" : "\(WeatherFormat.roughDistance(km)) away"
            copy.skySource = "someone's report \(away), \(ago)"
        }
        // The 15-minute slot holding now follows the report, so Next 2 hours doesn't say "dry"
        // under a "Raining" card (or rain under a "Cloudy" one).
        if let i = copy.minutely.firstIndex(where: { $0.time <= now && $0.time.addingTimeInterval(900) > now }) {
            let s = report.kind.slot
            let old = copy.minutely[i]
            let keep = report.kind.isWet && old.isWet && old.kind == PrecipitationSlot.kind(rain: s.rain, snowfall: s.snow)
            if !keep {
                copy.minutely[i] = PrecipitationSlot(time: old.time, precipitation: s.rain + s.snow * 0.7,
                                                     rain: s.rain, snowfall: s.snow)
            }
        }
        return copy
    }
}

/// Reports made on this phone, kept for an hour. The widget can't read the app's storage (no app
/// group), so it gets the same reports back from the relay.
public enum ConditionReportStore {
    private static let key = "conditionReports"
    static let keep: TimeInterval = 3600

    public static func mine(now: Date = Date()) -> [ConditionReport] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([ConditionReport].self, from: data) else { return [] }
        return all.filter { now.timeIntervalSince($0.time) < keep }
    }

    public static func add(_ r: ConditionReport) {
        save(mine() + [r])
    }

    /// Undo: forgets this phone's reports near `c`, and returns their ids so the relay can drop them.
    @discardableResult
    public static func removeMine(near c: Coordinate) -> [String] {
        let all = mine()
        let gone = all.filter { EnvironmentCanadaProvider.distanceKm($0.coordinate, c) <= ConditionReport.maxKm }
        save(all.filter { r in !gone.contains { $0.id == r.id } })
        return gone.map(\.id)
    }

    private static func save(_ list: [ConditionReport]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// This phone's reports plus the relay's, without counting this phone's twice.
    public static func merged(mine: [ConditionReport], relay: [ConditionReport]) -> [ConditionReport] {
        mine + relay.filter { r in !mine.contains { $0.id == r.id } }
    }
}

/// The relay's side: POST /v1/report sends one, GET /v1/reports lists the last hour's within 15 km.
public extension RelayExtrasProvider {
    private struct Wire: Codable {
        let id: String
        let kind: String
        let t: Double
        let lat: Double
        let lon: Double
    }

    func send(_ r: ConditionReport) async -> Bool {
        var req = URLRequest(url: reportsHost.appendingPathComponent("v1/report"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Wire(id: r.id, kind: r.kind.rawValue, t: r.time.timeIntervalSince1970,
                                                      lat: (r.latitude * 1000).rounded() / 1000,
                                                      lon: (r.longitude * 1000).rounded() / 1000))
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Undo on the relay too, so a mistaken tap doesn't stay on family phones or in the learner.
    func withdraw(ids: [String]) async {
        for id in ids {
            var req = URLRequest(url: reportsHost.appendingPathComponent("v1/report"), timeoutInterval: 6)
            req.httpMethod = "DELETE"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(["id": id])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func reports(near c: Coordinate) async -> [ConditionReport] {
        var parts = URLComponents(url: reportsHost.appendingPathComponent("v1/reports"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.3f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.3f", c.longitude)),
        ]
        struct R: Decodable { let reports: [Wire] }
        guard let url = parts.url,
              let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(R.self, from: data) else { return [] }
        return decoded.reports.compactMap { w in
            guard let kind = ReportKind(rawValue: w.kind) else { return nil }
            return ConditionReport(id: w.id, kind: kind, time: Date(timeIntervalSince1970: w.t),
                                   at: Coordinate(latitude: w.lat, longitude: w.lon), mine: false)
        }
    }
}
