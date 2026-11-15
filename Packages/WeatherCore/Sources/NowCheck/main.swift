import Foundation
import WeatherCore

// Hourly real-data check (.github/workflows/now-check.yml): runs the app's own "now" pipeline for
// Milton against live services and prints MISMATCH lines when its sky or temperature disagrees
// with the radar over the spot or the forecast model.

let milton = Coordinate(latitude: 43.513, longitude: -79.882)

/// Up to three tries, since a CI runner's first request to a service sometimes times out.
func attempt<T>(_ f: () async throws -> T?) async -> (T?, String?) {
    var lastError = "no data"
    for n in 1...3 {
        do { if let v = try await f() { return (v, nil) }; lastError = "no data" }
        catch { lastError = (error as NSError).localizedDescription }
        if n < 3 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
    }
    return (nil, lastError)
}

let (base, forecastError) = await attempt { try await OpenMeteoProvider().forecast(for: milton) }
guard let base else {
    // An outage isn't a wrong reading, so it doesn't open an issue.
    print("SKIPPED: forecast unavailable after 3 tries (\(forecastError ?? "nil"))")
    exit(0)
}
let (observation, obsError) = await attempt { try await HyperlocalObservationProvider().observation(near: milton) }
let (radar, radarError) = await attempt { try await ECCCRadarProvider().now(at: milton) }
let shown = base.applying(observation).applyingRadar(radar)

func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }

print("## Now check for Milton, \(ISO8601DateFormatter().string(from: Date()))")
print("- App shows: \(f(shown.current.temperature))°C, \(shown.current.condition.description) — \(shown.observation?.conditionText ?? "no station text")")
print("- Sky source: \(shown.skySource ?? "the forecast")")
print("- Readings from: \(observation.map { "\($0.stationName), \(f($0.distanceKm)) km" } ?? "none (\(obsError ?? "no station"))")")
if let o = observation {
    print("- Station sky: \(o.conditionText ?? "–") from \(o.skyStationName ?? o.stationName), \(f(o.skyDistanceKm ?? o.distanceKm)) km")
}
print("- Radar over Milton: " + (radar.map { "rain \(f($0.rainMmPerHour)) mm/h, snow \(f($0.snowCmPerHour)) cm/h at \($0.time)" }
                                 ?? "unavailable (\(radarError ?? "no recent frame"))"))
print("- Model now: \(f(base.current.temperature))°C, \(base.current.condition.description), \(f(base.current.precipitation)) mm")

var problems: [String] = []
if shown.current.condition.isPrecipitation, let r = radar, !r.isPrecipitating {
    problems.append("app says \(shown.current.condition.description) but the radar over Milton is dry")
}
if !shown.current.condition.isPrecipitation, let r = radar, r.rainMmPerHour >= 0.5 || r.snowCmPerHour >= 0.3 {
    problems.append("app says \(shown.current.condition.description) but the radar shows \(f(r.rainMmPerHour)) mm/h")
}
if shown.current.condition.isPrecipitation, radar == nil, shown.skySource == nil, (base.current.precipitation ?? 0) == 0 {
    problems.append("app says \(shown.current.condition.description) with no radar and a dry model")
}
if abs(shown.current.temperature - base.current.temperature) > 4 {
    problems.append("app temperature \(f(shown.current.temperature))° is over 4° from the model's \(f(base.current.temperature))°")
}
if radar == nil { print("- Note: radar unavailable, so the sky couldn't be cross-checked") }
for p in problems { print("MISMATCH: \(p)") }
if problems.isEmpty { print("OK: sources agree") }
