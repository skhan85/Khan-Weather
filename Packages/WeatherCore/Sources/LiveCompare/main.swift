#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
@testable import WeatherCore

/// Temporary: prints what the app shows for Milton right now, field by field, for a side-by-side check.
enum LiveCompare {
    static func run() async throws {
        let target = Coordinate(latitude: 43.5085, longitude: -79.8850)
        let observed = try? await HyperlocalObservationProvider().observation(near: target)
        let weights = await RelayExtrasProvider().regionalWeights(near: target)
        let base = try await OpenMeteoProvider().forecast(for: target, anchor: { observed?.blendAnchor }, regionalWeights: { weights })
        let google = await RelayExtrasProvider().googleHourly(near: target)
        let mosmix = await RelayExtrasProvider().mosmixHourly(near: target)
        let radar = try? await ECCCRadarProvider().now(at: target)
        let nc = await RelayExtrasProvider().nowcast(near: target, cold: false)
        let fc = base.applyingMosmixHourly(mosmix).applyingGoogleHourly(google).applying(observed)
            .applyingRadar(radar).applyingRadarNowcast(nc, radarNow: radar).calibratingEnsemblePop().agreeingNowWithNowcast()
        let air = try? await AirQualityProvider().airQuality(at: target)
        let tz = fc.timeZone
        let df = DateFormatter(); df.timeZone = tz; df.dateFormat = "EEE d HH:mm"
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
        var out = "## App for Milton at \(df.string(from: Date()))\n"
        let c = fc.current
        out += "- now: \(f(c.temperature))° \(c.condition.description), feels \(f(c.feelsLike)) (\(c.feelsLikeKind)), RH \(f(c.humidity)), wind \(f(c.windSpeed)) from \(f(c.windDirection)) gust \(f(c.windGusts)), pressure \(f(c.pressure)), precip \(f(c.precipitation))\n"
        out += "- obs: \(observed.map { "\($0.stationName) \(f($0.distanceKm)) km \(f($0.temperature))° \($0.conditionText ?? "-") at \(df.string(from: $0.time))" } ?? "none")\n"
        out += "- sky source: \(fc.skySource ?? "forecast"); radar: \(radar.map { "rain \(f($0.rainMmPerHour)) at \(df.string(from: $0.time))" } ?? "none")\n"
        out += "- nowcast: \(fc.nowcast()?.text ?? "none"); relay nowcast frame: \(nc.map { "\($0)".prefix(200) } ?? "none")\n"
        for h in (fc.recentHours ?? []) + fc.hourly.prefix(8) {
            out += "  - hour \(df.string(from: h.time)): \(f(h.temperature))° feels \(f(h.feelsLike)) pop \(f(h.precipitationProbability)) mm \(f(h.precipitation)) wind \(f(h.windSpeed)) dir \(f(h.windDirection)) RH \(f(h.humidity)) dew \(f(h.dewPoint)) uv \(f(h.uvIndex)) vis \(f(h.visibility)) p \(f(h.pressure)) \(h.condition.description)\n"
        }
        for d in fc.displayDaily().prefix(6) {
            out += "  - day \(df.string(from: d.date)): \(f(d.high))/\(f(d.low)) pop \(f(d.precipitationProbability)) rain \(f(d.rainSum)) snow \(f(d.snowfallSum)) uvmax \(f(d.uvIndexMax)) \(d.condition.description) sunrise \(d.sunrise.map(df.string) ?? "-") sunset \(d.sunset.map(df.string) ?? "-")\n"
        }
        out += "- air: usAQI \(f(air?.usAQI)) AQHI \(f(air?.aqhi)) \(air?.aqhiStation ?? "")\n"
        print(out)
        try? out.write(toFile: "live-compare.md", atomically: true, encoding: .utf8)
    }
}

try await LiveCompare.run()
