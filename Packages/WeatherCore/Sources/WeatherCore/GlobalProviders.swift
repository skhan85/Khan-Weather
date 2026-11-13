import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Free, keyless station observations and alerts outside Canada:
// US National Weather Service, Germany's DWD via Bright Sky, and airport METARs worldwide.

public typealias HTTPLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

let defaultLoader: HTTPLoader = { try await URLSession.shared.data(for: $0) }

/// NWS asks every client to identify itself.
let userAgent = "KhanWeather/0.1 (github.com/skhan85/Khan-Weather)"

func fetch(_ url: URL, loader: HTTPLoader, accept: String? = nil) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
    let (data, response) = try await loader(request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw ForecastError.httpStatus(http.statusCode)
    }
    return data
}

/// Rough boxes to decide which national services to ask. Overlap is fine; each returns nil when it has nothing.
enum Region {
    static func inUS(_ c: Coordinate) -> Bool {
        (24...50).contains(c.latitude) && (-125 ... -66).contains(c.longitude)      // lower 48
            || (51...72).contains(c.latitude) && (-170 ... -129).contains(c.longitude) // Alaska
            || (18...23).contains(c.latitude) && (-161 ... -154).contains(c.longitude) // Hawaii
    }
    static func inGermany(_ c: Coordinate) -> Bool {
        (47.2...55.1).contains(c.latitude) && (5.8...15.1).contains(c.longitude)
    }
    static func inCanada(_ c: Coordinate) -> Bool {
        (41.6...84).contains(c.latitude) && (-141 ... -52).contains(c.longitude)
    }
}

extension WeatherCondition {
    /// From words like "Light Rain and Fog/Mist" or "Mostly Cloudy".
    init?(text: String?) {
        guard let t = text?.lowercased(), !t.isEmpty else { return nil }
        if t.contains("thunder") { self = .thunderstorm }
        else if t.contains("freezing rain") { self = .freezingRain }
        else if t.contains("freezing drizzle") { self = .freezingDrizzle }
        else if t.contains("snow") || t.contains("sleet") { self = .snow }
        else if t.contains("drizzle") { self = .drizzle }
        else if t.contains("shower") { self = .rainShowers }
        else if t.contains("rain") { self = .rain }
        else if t.contains("fog") || t.contains("mist") || t.contains("haze") { self = .fog }
        else if t.contains("overcast") || t == "cloudy" || t.contains("mostly cloudy") { self = .overcast }
        else if t.contains("partly") || t.contains("cloud") { self = .partlyCloudy }
        else if t.contains("clear") || t.contains("sunny") || t.contains("fair") { self = .clear }
        else { return nil }
    }

    /// From METAR present weather ("-RA BR") and cloud cover ("OVC").
    init?(metarWeather wx: String?, cover: String?) {
        let w = wx ?? ""
        if w.contains("TS") { self = .thunderstorm }
        else if w.contains("FZRA") { self = .freezingRain }
        else if w.contains("FZDZ") { self = .freezingDrizzle }
        else if w.contains("SN") || w.contains("SG") || w.contains("PL") { self = .snow }
        else if w.contains("SHRA") { self = .rainShowers }
        else if w.contains("RA") { self = .rain }
        else if w.contains("DZ") { self = .drizzle }
        else if w.contains("FG") || w.contains("BR") || w.contains("HZ") { self = .fog }
        else {
            switch cover?.uppercased() {
            case "SKC", "CLR", "CAVOK", "NSC", "NCD": self = .clear
            case "FEW": self = .mainlyClear
            case "SCT", "BKN": self = .partlyCloudy
            case "OVC", "OVX": self = .overcast
            default: return nil
            }
        }
    }
}

/// Relative humidity (%) from temperature and dew point, Magnus formula.
func relativeHumidity(temperature t: Double, dewPoint td: Double) -> Double {
    let a = 17.625, b = 243.04
    return min(100, max(0, 100 * exp(a * td / (b + td) - a * t / (b + t))))
}

// MARK: - US: National Weather Service

public struct NWSObservationProvider: ObservationProvider {
    public let attribution = "Observations: US National Weather Service"
    private let loader: HTTPLoader
    /// Stations farther than this are skipped.
    let maxDistanceKm: Double = 40
    let maxAge: TimeInterval = 2 * 3600

    public init(loader: @escaping HTTPLoader = defaultLoader) { self.loader = loader }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        guard Region.inUS(coordinate) else { return nil }
        let c = coordinate.rounded
        let points = try await fetch(URL(string: "https://api.weather.gov/points/\(c.latitude),\(c.longitude)")!,
                                     loader: loader, accept: "application/geo+json")
        guard let stationsURL = try Self.stationsURL(points) else { return nil }
        let stations = try Self.parseStations(try await fetch(stationsURL, loader: loader, accept: "application/geo+json"),
                                              near: coordinate, maxDistanceKm: maxDistanceKm)
        // Nearest first; small airports sometimes go quiet, so try a few.
        for station in stations.prefix(3) {
            let url = URL(string: "https://api.weather.gov/stations/\(station.id)/observations/latest")!
            guard let data = try? await fetch(url, loader: loader, accept: "application/geo+json"),
                  let obs = try? Self.parseObservation(data, station: station, now: Date(), maxAge: maxAge) else { continue }
            return obs
        }
        return nil
    }

    struct Station { let id: String; let name: String; let distanceKm: Double }

    static func stationsURL(_ data: Data) throws -> URL? {
        struct R: Decodable { struct P: Decodable { let observationStations: String? }; let properties: P }
        return try JSONDecoder().decode(R.self, from: data).properties.observationStations.flatMap(URL.init(string:))
    }

    static func parseStations(_ data: Data, near c: Coordinate, maxDistanceKm: Double) throws -> [Station] {
        struct R: Decodable {
            struct F: Decodable {
                struct G: Decodable { let coordinates: [Double] }
                struct P: Decodable { let stationIdentifier: String; let name: String }
                let geometry: G?
                let properties: P
            }
            let features: [F]
        }
        return try JSONDecoder().decode(R.self, from: data).features.compactMap { f in
            guard let g = f.geometry, g.coordinates.count >= 2 else { return nil }
            let d = EnvironmentCanadaProvider.distanceKm(c, Coordinate(latitude: g.coordinates[1], longitude: g.coordinates[0]))
            return d <= maxDistanceKm ? Station(id: f.properties.stationIdentifier, name: f.properties.name, distanceKm: d) : nil
        }.sorted { $0.distanceKm < $1.distanceKm }
    }

    static func parseObservation(_ data: Data, station: Station, now: Date, maxAge: TimeInterval) throws -> Observation? {
        struct Q: Decodable { let value: Double? }
        struct R: Decodable {
            struct P: Decodable {
                let timestamp: String?
                let textDescription: String?
                let temperature: Q?
                let dewpoint: Q?
                let windSpeed: Q?
                let windDirection: Q?
                let relativeHumidity: Q?
            }
            let properties: P
        }
        let p = try JSONDecoder().decode(R.self, from: data).properties
        guard let t = p.temperature?.value,
              let time = p.timestamp.flatMap(EnvironmentCanadaProvider.parseDate),
              now.timeIntervalSince(time) < maxAge else { return nil }
        var humidity = p.relativeHumidity?.value
        if humidity == nil, let td = p.dewpoint?.value { humidity = relativeHumidity(temperature: t, dewPoint: td) }
        var o = Observation(stationName: station.name, observedAt: time, temperature: t, humidity: humidity,
                            windSpeed: p.windSpeed?.value, windDirection: p.windDirection?.value,
                            condition: WeatherCondition(text: p.textDescription),
                            conditionText: (p.textDescription?.isEmpty ?? true) ? nil : p.textDescription,
                            distanceKm: station.distanceKm)
        o.dataProvider = "NWS"
        return o
    }
}

public struct NWSAlertProvider: AlertProvider {
    private let loader: HTTPLoader
    public init(loader: @escaping HTTPLoader = defaultLoader) { self.loader = loader }

    public func alerts(near coordinate: Coordinate) async throws -> [WeatherAlert] {
        guard Region.inUS(coordinate) else { return [] }
        let c = coordinate.rounded
        let url = URL(string: "https://api.weather.gov/alerts/active?point=\(c.latitude),\(c.longitude)")!
        return try Self.parse(try await fetch(url, loader: loader, accept: "application/geo+json"), now: Date())
    }

    static func parse(_ data: Data, now: Date) throws -> [WeatherAlert] {
        struct R: Decodable {
            struct F: Decodable {
                struct P: Decodable {
                    let id: String?
                    let event: String?
                    let severity: String?
                    let headline: String?
                    let description: String?
                    let instruction: String?
                    let areaDesc: String?
                    let effective: String?
                    let expires: String?
                    let ends: String?
                    let status: String?
                    let messageType: String?
                }
                let properties: P
            }
            let features: [F]
        }
        return try JSONDecoder().decode(R.self, from: data).features.compactMap { f in
            let p = f.properties
            guard p.status == nil || p.status == "Actual", p.messageType != "Cancel" else { return nil }
            let ends = p.ends.flatMap(EnvironmentCanadaProvider.parseDate)
            let expires = p.expires.flatMap(EnvironmentCanadaProvider.parseDate)
            if let end = ends ?? expires, end <= now { return nil }
            let event = p.event ?? "Weather alert"
            let lower = event.lowercased()
            let kind: WeatherAlert.Kind = lower.contains("warning") ? .warning : lower.contains("watch") ? .watch
                : lower.contains("advisory") ? .advisory : lower.contains("statement") ? .statement : .other
            let risk: WeatherAlert.Risk
            switch p.severity {
            case "Extreme": risk = .red
            case "Severe": risk = .orange
            case "Moderate", "Minor": risk = .yellow
            default: risk = .unknown
            }
            var text = p.description ?? p.headline ?? ""
            if let i = p.instruction, !i.isEmpty { text += "\n\n" + i }
            return WeatherAlert(id: p.id ?? UUID().uuidString, title: event, kind: kind, risk: risk, text: text,
                                area: p.areaDesc, issuedAt: p.effective.flatMap(EnvironmentCanadaProvider.parseDate),
                                expiresAt: expires, eventEndsAt: ends, source: "US National Weather Service")
        }.sorted { $0.kind < $1.kind }
    }
}

// MARK: - Germany: DWD via Bright Sky

public struct BrightSkyProvider: ObservationProvider {
    public let attribution = "Observations: Deutscher Wetterdienst via Bright Sky"
    private let loader: HTTPLoader
    let maxAge: TimeInterval = 2 * 3600

    public init(loader: @escaping HTTPLoader = defaultLoader) { self.loader = loader }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        guard Region.inGermany(coordinate) else { return nil }
        let c = coordinate.rounded
        let url = URL(string: "https://api.brightsky.dev/current_weather?lat=\(c.latitude)&lon=\(c.longitude)")!
        return try Self.parse(try await fetch(url, loader: loader), now: Date(), maxAge: maxAge)
    }

    static func parse(_ data: Data, now: Date, maxAge: TimeInterval) throws -> Observation? {
        struct R: Decodable {
            struct W: Decodable {
                let timestamp: String?
                let temperature: Double?
                let relative_humidity: Double?
                let wind_speed_10: Double?
                let wind_direction_10: Double?
                let condition: String?
                let icon: String?
                let source_id: Int?
            }
            struct S: Decodable { let id: Int?; let station_name: String?; let distance: Double? }
            let weather: W
            let sources: [S]?
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        let w = r.weather
        guard let t = w.temperature, let time = w.timestamp.flatMap(EnvironmentCanadaProvider.parseDate),
              now.timeIntervalSince(time) < maxAge else { return nil }
        let source = r.sources?.first { $0.id == w.source_id } ?? r.sources?.first
        let condition: WeatherCondition?
        switch w.condition {
        case "rain": condition = .rain
        case "sleet", "snow", "hail": condition = .snow
        case "thunderstorm": condition = .thunderstorm
        case "fog": condition = .fog
        default:
            switch w.icon {
            case "clear-day", "clear-night": condition = .clear
            case "partly-cloudy-day", "partly-cloudy-night": condition = .partlyCloudy
            case "cloudy": condition = .overcast
            default: condition = nil
            }
        }
        var o = Observation(stationName: source?.station_name ?? "DWD station", observedAt: time, temperature: t,
                            humidity: w.relative_humidity, windSpeed: w.wind_speed_10, windDirection: w.wind_direction_10,
                            condition: condition, distanceKm: source?.distance.map { $0 / 1000 })
        o.dataProvider = "DWD"
        return o
    }
}

public struct BrightSkyAlertProvider: AlertProvider {
    private let loader: HTTPLoader
    public init(loader: @escaping HTTPLoader = defaultLoader) { self.loader = loader }

    public func alerts(near coordinate: Coordinate) async throws -> [WeatherAlert] {
        guard Region.inGermany(coordinate) else { return [] }
        let c = coordinate.rounded
        let url = URL(string: "https://api.brightsky.dev/alerts?lat=\(c.latitude)&lon=\(c.longitude)")!
        return try Self.parse(try await fetch(url, loader: loader), now: Date())
    }

    static func parse(_ data: Data, now: Date) throws -> [WeatherAlert] {
        struct R: Decodable {
            struct A: Decodable {
                let id: Int?
                let alert_id: String?
                let event_en: String?
                let headline_en: String?
                let description_en: String?
                let instruction_en: String?
                let severity: String?
                let effective: String?
                let onset: String?
                let expires: String?
            }
            let alerts: [A]
        }
        return try JSONDecoder().decode(R.self, from: data).alerts.compactMap { a in
            let expires = a.expires.flatMap(EnvironmentCanadaProvider.parseDate)
            if let expires, expires <= now { return nil }
            let event = a.event_en ?? a.headline_en ?? "Weather warning"
            let risk: WeatherAlert.Risk
            switch a.severity {
            case "extreme": risk = .red
            case "severe": risk = .orange
            case "moderate", "minor": risk = .yellow
            default: risk = .unknown
            }
            var text = a.description_en ?? ""
            if let i = a.instruction_en, !i.isEmpty { text += "\n\n" + i }
            return WeatherAlert(id: a.alert_id ?? String(a.id ?? 0),
                                title: event.prefix(1).uppercased() + event.dropFirst(),
                                kind: .warning, risk: risk, text: text,
                                issuedAt: a.effective.flatMap(EnvironmentCanadaProvider.parseDate),
                                expiresAt: expires, source: "Deutscher Wetterdienst")
        }
    }
}

// MARK: - Worldwide: airport METARs

public struct METARProvider: ObservationProvider {
    public let attribution = "Airport observations: NOAA Aviation Weather Center"
    private let loader: HTTPLoader
    let maxDistanceKm: Double = 40
    let maxAge: TimeInterval = 3 * 3600

    public init(loader: @escaping HTTPLoader = defaultLoader) { self.loader = loader }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        let c = coordinate.rounded
        let d = 0.4
        let bbox = [c.latitude - d, c.longitude - d * 1.5, c.latitude + d, c.longitude + d * 1.5]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
        let url = URL(string: "https://aviationweather.gov/api/data/metar?bbox=\(bbox)&format=json")!
        return try Self.parse(try await fetch(url, loader: loader), near: coordinate, now: Date(),
                              maxDistanceKm: maxDistanceKm, maxAge: maxAge)
    }

    static func parse(_ data: Data, near c: Coordinate, now: Date, maxDistanceKm: Double, maxAge: TimeInterval) throws -> Observation? {
        struct M: Decodable {
            let name: String?
            let icaoId: String?
            let lat: Double?
            let lon: Double?
            let obsTime: Double?
            let temp: Double?
            let dewp: Double?
            let wdir: Flexible?
            let wspd: Double?
            let wxString: String?
            let cover: String?
        }
        /// "VRB" wind direction or "6+" visibility come as strings.
        struct Flexible: Decodable {
            let number: Double?
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                number = (try? c.decode(Double.self)) ?? (try? c.decode(String.self)).flatMap(Double.init)
            }
        }
        let list = try JSONDecoder().decode([M].self, from: data)
        let best = list.compactMap { m -> (M, Double, Date)? in
            guard let lat = m.lat, let lon = m.lon, m.temp != nil, let t = m.obsTime else { return nil }
            let time = Date(timeIntervalSince1970: t)
            let d = EnvironmentCanadaProvider.distanceKm(c, Coordinate(latitude: lat, longitude: lon))
            guard d <= maxDistanceKm, now.timeIntervalSince(time) < maxAge else { return nil }
            return (m, d, time)
        }.min { $0.1 < $1.1 }
        guard let (m, distance, time) = best, let temp = m.temp else { return nil }
        let name = (m.name ?? m.icaoId ?? "Airport").components(separatedBy: ",").first ?? "Airport"
        var o = Observation(stationName: name, observedAt: time, temperature: temp,
                            humidity: m.dewp.map { relativeHumidity(temperature: temp, dewPoint: $0) },
                            windSpeed: m.wspd.map { $0 * 1.852 }, windDirection: m.wdir?.number,
                            condition: WeatherCondition(metarWeather: m.wxString, cover: m.cover),
                            distanceKm: distance)
        o.dataProvider = "METAR"
        return o
    }
}

// MARK: - Routing

/// Picks the right national services for the spot, falling back to the nearest airport anywhere.
public struct WorldObservationProvider: ObservationProvider {
    public let attribution = "Observations: national weather services and airports"
    private let canada: ObservationProvider
    private let us: ObservationProvider
    private let germany: ObservationProvider
    private let airports: ObservationProvider

    public init(canada: ObservationProvider = CanadaObservationProvider(),
                us: ObservationProvider = NWSObservationProvider(),
                germany: ObservationProvider = BrightSkyProvider(),
                airports: ObservationProvider = METARProvider()) {
        self.canada = canada
        self.us = us
        self.germany = germany
        self.airports = airports
    }

    public func observation(near coordinate: Coordinate) async throws -> Observation? {
        if Region.inCanada(coordinate), let o = try? await canada.observation(near: coordinate) {
            return o
        }
        async let a = try? us.observation(near: coordinate)
        async let b = try? germany.observation(near: coordinate)
        async let c = try? airports.observation(near: coordinate)
        let found = [await a ?? nil, await b ?? nil, await c ?? nil].compactMap { $0 }
        return found.min { ($0.distanceKm ?? .infinity) < ($1.distanceKm ?? .infinity) }
    }
}

public struct WorldAlertProvider: AlertProvider {
    private let providers: [AlertProvider]

    public init(providers: [AlertProvider] = [ECCCAlertProvider(), NWSAlertProvider(), BrightSkyAlertProvider()]) {
        self.providers = providers
    }

    public func alerts(near coordinate: Coordinate) async throws -> [WeatherAlert] {
        var all: [WeatherAlert] = []
        var failures = 0
        for p in providers {
            do { all += try await p.alerts(near: coordinate) } catch { failures += 1 }
        }
        // Only report failure when every service failed, so the app keeps its last list.
        if failures == providers.count { throw ForecastError.missingData("alerts") }
        return all.sorted { $0.kind < $1.kind }
    }
}
