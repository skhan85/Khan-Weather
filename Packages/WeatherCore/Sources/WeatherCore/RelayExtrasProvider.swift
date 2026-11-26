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

public struct RelayGoogleHourly: Codable, Equatable, Sendable {
    public struct Hour: Codable, Equatable, Sendable {
        public let epoch: Double
        public let temp: Double
        public let feels_like: Double?
        public let dew_point: Double?
        public let wind_kmh: Double?
        public let gust_kmh: Double?
        public let pop: Double?
        public let precip_mm: Double?
        public let snow_mm: Double?
    }
    public let generated: Double?
    public let provider: String?
    public let hours: [Hour]
}

public extension Forecast {
    /// Blends Google Weather's hourly forecast (`ModelBlend.googleWeight` over `ModelBlend.googleHorizonHours`)
    /// into `hourly` and updates daily high/low and feels-like consistently.
    func applyingGoogleHourly(_ gh: RelayGoogleHourly?) -> Forecast {
        guard let gh, !gh.hours.isEmpty, !hourly.isEmpty else { return self }
        var byHour: [Int: RelayGoogleHourly.Hour] = [:]
        for g in gh.hours {
            let k = Int((g.epoch / 3600).rounded()) * 3600
            byHour[k] = g
        }
        var copy = self
        let gwWeight = ModelBlend.googleWeight
        let omBaseWeight = 1 - gwWeight
        let cutoff = current.time.addingTimeInterval(ModelBlend.googleHorizonHours * 3600)
        var changed = false
        var touchedHours = Set<Int>()
        copy.hourly = hourly.map { hour in
            guard hour.time <= cutoff else { return hour }
            let k = Int((hour.time.timeIntervalSince1970 / 3600).rounded()) * 3600
            guard let g = byHour[k] else { return hour }
            var h = hour
            h.temperature = omBaseWeight * h.temperature + gwWeight * g.temp
            if let dp = h.dewPoint, let gdp = g.dew_point {
                h.dewPoint = min(h.temperature, omBaseWeight * dp + gwWeight * gdp)
            }
            if let w = h.windSpeed, let gw = g.wind_kmh {
                h.windSpeed = max(0, omBaseWeight * w + gwWeight * gw)
            }
            touchedHours.insert(Int(hour.time.timeIntervalSince1970))
            changed = true
            return h
        }
        guard changed else { return self }
        let hiAllow = extremesIncludePeak == true ? ModelBlend.highAllowance : 0
        let loAllow = extremesIncludePeak == true ? ModelBlend.lowAllowance : 0
        copy.daily = copy.daily.map { day in
            let hrs = copy.hours(on: day)
            guard hrs.count >= 18 else { return day }
            let touched = hrs.filter { touchedHours.contains(Int($0.time.timeIntervalSince1970)) }.count
            guard touched > 0 else { return day }
            let omShare = 1 - gwWeight * (Double(touched) / Double(hrs.count))
            var d = day
            d.phaseHighLift = day.phaseHighLift.map { $0 * omShare }
            d.phaseLowDrop = day.phaseLowDrop.map { $0 * omShare }
            d.high = hrs.map(\.temperature).max()! + (d.phaseHighLift ?? 0) + hiAllow
            d.low = hrs.map(\.temperature).min()! - (d.phaseLowDrop ?? 0) - loAllow
            return d
        }
        if current.time <= cutoff,
           let gNow = Self.interpolatedGoogle(gh.hours, at: current.time) {
            copy.current.temperature = omBaseWeight * copy.current.temperature + gwWeight * gNow.temperature
            if let w = copy.current.windSpeed, let gw = gNow.wind {
                copy.current.windSpeed = max(0, omBaseWeight * w + gwWeight * gw)
            }
        }
        return copy.withStandardFeelsLike()
    }

    private static func interpolatedGoogle(_ hours: [RelayGoogleHourly.Hour], at time: Date) -> (temperature: Double, wind: Double?)? {
        let sorted = hours.sorted { $0.epoch < $1.epoch }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let target = time.timeIntervalSince1970
        guard target >= first.epoch - 1800, target <= last.epoch + 1800 else { return nil }
        if target <= first.epoch { return (first.temp, first.wind_kmh) }
        if target >= last.epoch { return (last.temp, last.wind_kmh) }
        guard let afterIdx = sorted.firstIndex(where: { $0.epoch >= target }), afterIdx > 0 else {
            return (first.temp, first.wind_kmh)
        }
        let a = sorted[afterIdx - 1], b = sorted[afterIdx]
        let span = b.epoch - a.epoch
        let f = span > 0 ? (target - a.epoch) / span : 0
        let t = a.temp + (b.temp - a.temp) * f
        let w = a.wind_kmh.flatMap { wa in b.wind_kmh.map { wb in wa + (wb - wa) * f } } ?? a.wind_kmh ?? b.wind_kmh
        return (t, w)
    }

    /// Merges 6-minute radar extrapolation from the relay into 15-minute `minutely` slots.
    func applyingRadarNowcast(_ nc: RelayNowcast?) -> Forecast {
        guard let nc, !nc.slots.isEmpty, !minutely.isEmpty else { return self }
        var copy = self
        let temp = current.temperature
        let rh = current.humidity ?? 100
        let startEpoch = minutely[0].time.timeIntervalSince1970
        let nearRadarClean = nc.slots.filter { $0.epoch >= startEpoch - 360 && $0.epoch < startEpoch + 2700 }
            .allSatisfy { $0.precip_mmh <= 0 }
        let dryVeto = (observation?.gaugesSayDry == true) && temp > 1 && nearRadarClean
        copy.minutely = minutely.map { slot in
            let start = slot.time.timeIntervalSince1970
            let end = start + 900
            if dryVeto, start < startEpoch + 2700, slot.snowfall == 0, slot.precipitation < 0.5 {
                return PrecipitationSlot(time: slot.time, precipitation: 0, rain: 0, snowfall: 0)
            }
            let matching = nc.slots.filter { $0.epoch >= start && $0.epoch < end }
            guard !matching.isEmpty else { return slot }
            let rawRain = matching.map(\.rain_mmh).max() ?? 0
            let rawSnow = matching.map(\.snow_cmh).max() ?? 0
            let rainRate: Double
            let snowRate: Double
            if temp <= 1 {
                rainRate = 0
                snowRate = max(rawSnow, rawRain)
            } else if temp >= 3 {
                rainRate = max(rawRain, rawSnow)
                snowRate = 0
            } else {
                rainRate = rawRain
                snowRate = rawSnow
            }
            let peakRate = max(rainRate, snowRate)
            let minRate = (snowRate <= 0 && rh < 80) ? 1.0 : 0.50
            guard peakRate >= minRate else { return slot }
            let rain = rainRate >= minRate ? max(slot.rain, max(PrecipitationSlot.wetThreshold, rainRate / 4.0)) : slot.rain
            let snow = snowRate >= minRate ? max(slot.snowfall, max(PrecipitationSlot.wetThreshold, snowRate / 4.0)) : slot.snowfall
            let total = max(slot.precipitation, rain + snow)
            return PrecipitationSlot(time: slot.time, precipitation: total, rain: rain, snowfall: snow)
        }
        return copy
    }
    /// Ensures daily rain chance stays consistent with ensemble model peaks and precipitation totals.
    func calibratingEnsemblePop() -> Forecast {
        var copy = self
        copy.hourly = hourly.map { h in
            var out = h
            if let n = h.modelCount, n == 3, let w = h.modelsWet, let raw = h.precipitationProbability {
                let ens = (Double(w) / Double(n)) * 100.0
                out.precipitationProbability = (0.6 * raw + 0.4 * ens).rounded()
            }
            out.promoteLikelyPrecipitation()
            return out
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        copy.daily = daily.map { d in
            var out = d
            let dayHours = copy.hourly.filter { cal.isDate($0.time, inSameDayAs: d.date) }
            if dayHours.count >= 6, let ensMax = dayHours.compactMap(\.precipitationProbability).max(),
               let raw = d.precipitationProbability {
                out.precipitationProbability = (0.5 * raw + 0.5 * ensMax).rounded()
            }
            let totalMm = (out.rainSum ?? 0) + (out.snowfallSum ?? 0)
            if totalMm >= 10, let p = out.precipitationProbability {
                out.precipitationProbability = max(p, 65)
            } else if totalMm >= 5, out.condition.isPrecipitation, let p = out.precipitationProbability {
                out.precipitationProbability = max(p, 50)
            } else if totalMm >= 1, out.condition.isPrecipitation, let p = out.precipitationProbability {
                out.precipitationProbability = max(p, 40)
            } else if totalMm < 0.5, !out.condition.isPrecipitation, let p = out.precipitationProbability, p > 25 {
                out.precipitationProbability = 25
            }
            if (out.precipitationProbability ?? 0) < 30, totalMm < 1.0, out.condition.isPrecipitation {
                out.condition = .overcast
                out.summary = nil
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
        struct R: Decodable {
            let weights: [String: Double]?
            let diurnal_bias_3h: [Double]?
        }
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        if let bias = decoded.diurnal_bias_3h, bias.count == 8 {
            ModelBlend.setDiurnalBias(bias, for: c)
        }
        return decoded.weights
    }
    public func googleHourly(near c: Coordinate) async -> RelayGoogleHourly? {
        var parts = URLComponents(url: host.appendingPathComponent("v1/google-hourly"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", c.longitude)),
        ]
        guard let url = parts.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RelayGoogleHourly.self, from: data)
    }
}
