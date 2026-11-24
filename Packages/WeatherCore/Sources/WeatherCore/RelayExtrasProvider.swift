import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RelayHazards: Codable, Equatable, Sendable {
    public struct Lightning: Codable, Equatable, Sendable {
        public let count: Int
        public let distance_km: Double?
        public let bearing: String?
        public let observed: Double?
    }
    public struct Hail: Codable, Equatable, Sendable {
        public let distance_km: Double?
        public let bearing: String?
        public let max_size_mm: Double?
        public let severe: Bool?
    }
    public struct Road: Codable, Equatable, Sendable {
        public let surface: String?
        public let temp_c: Double?
        public let ice_mm: Double?
        public let snow_mm: Double?
        public let water_mm: Double?
    }

    public let generated: Double?
    public let lightning: Lightning?
    public let hail: Hail?
    public let road: Road?

    public struct Banner: Equatable, Sendable, Identifiable {
        public let id: String
        public let icon: String
        public let text: String
    }

    public var banners: [Banner] {
        var out: [Banner] = []
        if let l = lightning, l.count > 0 {
            let dist = l.distance_km.map { "\(Int($0.rounded())) km" } ?? "nearby"
            let dir = l.bearing.map { " \($0)" } ?? ""
            out.append(Banner(id: "lightning", icon: "bolt.fill",
                              text: "Lightning \(dist)\(dir) (\(l.count) recent strike\(l.count == 1 ? "" : "s"))."))
        }
        if let h = hail {
            let dist = h.distance_km.map { "\(Int($0.rounded())) km" } ?? "nearby"
            let dir = h.bearing.map { " \($0)" } ?? ""
            let size = (h.max_size_mm ?? 0) > 0 ? " (up to \(Int(h.max_size_mm!.rounded())) mm)" : ""
            out.append(Banner(id: "hail", icon: "cloud.hail.fill",
                              text: "Hail threat \(dist)\(dir)\(size)."))
        }
        if let r = road {
            let ice = r.ice_mm ?? 0
            let snow = r.snow_mm ?? 0
            let surf = (r.surface ?? "").lowercased()
            let wintry = ice >= 0.1 || snow >= 1.0 || surf.contains("ice") || surf.contains("snow") || surf.contains("slush") || surf.contains("freez")
            if wintry {
                let label = r.surface?.capitalized ?? "Wintry roads"
                let detail = ice >= 0.1 ? String(format: " (%.1f mm ice)", ice)
                    : (snow >= 1.0 ? String(format: " (%.0f mm snow)", snow) : "")
                out.append(Banner(id: "road", icon: "car.fill", text: "Roads: \(label)\(detail)."))
            }
        }
        return out
    }
}

public struct RelayConsensus: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable, Identifiable {
        public let provider: String
        public let temperature: Double
        public let feels_like: Double?
        public let humidity: Double?
        public let wind_kmh: Double?
        public let high: Double?
        public let low: Double?
        public let condition: String?
        public var id: String { provider }
    }
    public let generated: Double?
    public let sources: [Source]
    public let mean_temperature: Double?
}

public struct RelayNowcast: Codable, Equatable, Sendable {
    public struct Slot: Codable, Equatable, Sendable {
        public let time: String
        public let epoch: Double
        public let precip_mmh: Double
        public let rain_mmh: Double
        public let snow_cmh: Double
    }
    public let generated: Double?
    public let source: String?
    public let step_minutes: Int?
    public let slots: [Slot]
}

public extension Forecast {
    /// Merges 6-minute radar extrapolation from the relay into 15-minute `minutely` slots.
    func applyingRadarNowcast(_ nc: RelayNowcast?) -> Forecast {
        guard let nc, !nc.slots.isEmpty, !minutely.isEmpty else { return self }
        var copy = self
        let isSnow = current.temperature <= 0
        copy.minutely = minutely.map { slot in
            let start = slot.time.timeIntervalSince1970
            let end = start + 900
            let matching = nc.slots.filter { $0.epoch >= start && $0.epoch < end }
            guard !matching.isEmpty else { return slot }
            let peakRain = matching.map(\.rain_mmh).max() ?? 0
            let peakSnow = isSnow ? max(matching.map(\.snow_cmh).max() ?? 0, peakRain) : 0
            let peakRate = isSnow ? peakSnow : peakRain
            let minRate = (!isSnow && (current.humidity ?? 100) < 80) ? 1.0 : 0.50
            guard peakRate >= minRate else { return slot }
            let slotAmount = max(PrecipitationSlot.wetThreshold, peakRate / 4.0)
            let rain = isSnow ? slot.rain : max(slot.rain, slotAmount)
            let snow = isSnow ? max(slot.snowfall, slotAmount) : slot.snowfall
            let total = max(slot.precipitation, rain + snow)
            return PrecipitationSlot(time: slot.time, precipitation: total, rain: rain, snowfall: snow)
        }
        return copy
    }
    /// Blends hourly & daily rain chance with 8-model wet agreement so a single outlier model
    /// doesn't inflate dry days.
    func calibratingEnsemblePop() -> Forecast {
        var copy = self
        copy.hourly = hourly.map { h in
            guard let n = h.modelCount, n >= 3, let w = h.modelsWet, let raw = h.precipitationProbability else { return h }
            var out = h
            let ens = (Double(w) / Double(n)) * 100.0
            out.precipitationProbability = (0.6 * raw + 0.4 * ens).rounded()
            return out
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        copy.daily = daily.map { d in
            let dayHours = copy.hourly.filter { cal.isDate($0.time, inSameDayAs: d.date) }
            guard dayHours.count >= 6,
                  let ensMax = dayHours.compactMap(\.precipitationProbability).max() else { return d }
            var out = d
            if let raw = d.precipitationProbability {
                out.precipitationProbability = (0.5 * raw + 0.5 * ensMax).rounded()
            }
            return out
        }
        return copy
    }
}


public struct RelayExtrasProvider: Sendable {
    public static let defaultHost = URL(string: "https://weather-relay.khanofmilton.ca")!
    private let host: URL

    public init(host: URL = defaultHost) {
        self.host = host
    }

    public func hazards(near c: Coordinate, storms: Bool, cold: Bool) async -> RelayHazards? {
        guard storms || cold else { return nil }
        var parts = URLComponents(url: host.appendingPathComponent("v1/hazards"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
            URLQueryItem(name: "storms", value: storms ? "1" : "0"),
            URLQueryItem(name: "cold", value: cold ? "1" : "0"),
        ]
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RelayHazards.self, from: data)
    }

    public func consensus(near c: Coordinate) async -> RelayConsensus? {
        var parts = URLComponents(url: host.appendingPathComponent("v1/consensus"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
        ]
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RelayConsensus.self, from: data)
    }

    public func stations(near c: Coordinate) async -> [NetatmoStation] {
        var parts = URLComponents(url: host.appendingPathComponent("v1/netatmo"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
        ]
        struct R: Decodable { let stations: [NetatmoStation] }
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(R.self, from: data) else { return [] }
        return decoded.stations
    }
    public func nowcast(near c: Coordinate, cold: Bool = false) async -> RelayNowcast? {
        var parts = URLComponents(url: host.appendingPathComponent("v1/nowcast"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
            URLQueryItem(name: "cold", value: cold ? "1" : "0"),
        ]
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RelayNowcast.self, from: data)
    }
    public func regionalWeights(near c: Coordinate) async -> [String: Double]? {
        var parts = URLComponents(url: host.appendingPathComponent("v1/weights"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.2f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.2f", c.longitude)),
        ]
        struct R: Decodable { let weights: [String: Double]? }
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        return decoded.weights
    }
}
