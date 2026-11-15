import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WeatherCore

// Server-side weather notifications (.github/workflows/alert-push.yml).
//
// A sideloaded app on a free Apple ID can't receive real push notifications, and iOS rarely wakes
// such an app in the background, so its own notifications are unreliable. This runs the app's own
// alert, rain and frost logic on a GitHub runner every few minutes and sends anything new to the
// free ntfy app (ntfy.sh), which does deliver instantly on iPhone.
//
// Settings come from the environment:
//   NTFY_TOPIC        the ntfy topic to send to (keep it secret: anyone who knows it can read it)
//   PUSH_PLACES       "Name=lat,lon;Name=lat,lon", each optionally "...@topic" for its own topic.
//                     Defaults to Milton.
//   PUSH_ADVISORIES   "false" to send only warnings and watches
//   PUSH_RAIN, PUSH_FROST   "false" to turn those heads-ups off
//   STATE_FILE        where to remember what was already sent (kept between runs by the cache)
//   DRY_RUN           "true" prints instead of sending

let env = ProcessInfo.processInfo.environment
func flag(_ key: String) -> Bool { (env[key] ?? "true").lowercased() != "false" }

let server = (env["NTFY_SERVER"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://ntfy.sh")
let defaultTopic = env["NTFY_TOPIC"] ?? ""
let dryRun = (env["DRY_RUN"] ?? "").lowercased() == "true"
let statePath = env["STATE_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "alert-push-state.json"

struct Place { var name: String; var coordinate: Coordinate; var topic: String }

func parsePlaces(_ text: String) -> [Place] {
    text.split(separator: ";").compactMap { entry in
        var body = String(entry).trimmingCharacters(in: .whitespacesAndNewlines)
        var topic = defaultTopic
        if let at = body.lastIndex(of: "@") {
            topic = String(body[body.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<at])
        }
        let parts = body.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let nums = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 2 else { return nil }
        return Place(name: parts[0].trimmingCharacters(in: .whitespaces),
                     coordinate: Coordinate(latitude: nums[0], longitude: nums[1]), topic: topic)
    }
}

let placesText = env["PUSH_PLACES"].flatMap { $0.isEmpty ? nil : $0 } ?? "Milton=43.513,-79.882"
let places = parsePlaces(placesText)

guard dryRun || !defaultTopic.isEmpty || places.contains(where: { !$0.topic.isEmpty }) else {
    print("SKIPPED: no NTFY_TOPIC set, so there's nowhere to send notifications.")
    exit(0)
}

// MARK: Memory between runs

struct State: Codable {
    /// Alert id (plus topic) -> when to forget it.
    var alerts: [String: Double] = [:]
    /// Place name -> when the last rain heads-up went out.
    var rain: [String: Double] = [:]
    /// Place name -> local day of the last frost heads-up.
    var frost: [String: String] = [:]
}

var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))) ?? State()
let firstRun = !FileManager.default.fileExists(atPath: statePath)
let now = Date()
state.alerts = state.alerts.filter { $0.value > now.timeIntervalSince1970 }

// MARK: Sending

struct Message: Encodable {
    var topic: String
    var title: String
    var message: String
    var priority: Int
    var tags: [String]
}

@MainActor func send(_ m: Message) async {
    if dryRun || m.topic.isEmpty {
        print("WOULD SEND [\(m.priority)] \(m.title): \(m.message)")
        return
    }
    var request = URLRequest(url: URL(string: server)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(m)
    for n in 1...3 {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { print("SENT: \(m.title)"); return }
            print("ntfy answered \(code) for \(m.title)")
        } catch {
            print("ntfy send failed (try \(n)): \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
}

/// Up to three tries, since a runner's first request to a service sometimes times out.
func attempt<T>(_ f: () async throws -> T?) async -> T? {
    for n in 1...3 {
        if let v = try? await f() { return v }
        if n < 3 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
    }
    return nil
}

// MARK: Checks

let includeAdvisories = flag("PUSH_ADVISORIES")
let alertProvider = WorldAlertProvider()
let forecastProvider = OpenMeteoProvider()

@MainActor func checkAlerts(_ place: Place) async {
    guard let alerts = await attempt({ try await alertProvider.alerts(near: place.coordinate) }) else {
        print("\(place.name): alert services unavailable this run")
        return
    }
    print("\(place.name): \(alerts.count) active alert(s)")
    for a in alerts {
        switch a.kind {
        case .warning, .watch: break
        case .advisory, .statement, .other: if !includeAdvisories { continue }
        }
        let key = "\(place.topic)|\(a.id)"
        guard state.alerts[key] == nil else { continue }
        state.alerts[key] = (a.expiresAt ?? a.eventEndsAt ?? now.addingTimeInterval(2 * 86400)).timeIntervalSince1970 + 86400
        let firstParagraph = a.text.components(separatedBy: "\n\n")
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? a.text
        let priority: Int
        switch (a.kind, a.risk) {
        case (.warning, .red): priority = 5
        case (.warning, _), (.watch, _): priority = 4
        default: priority = 3
        }
        await send(Message(topic: place.topic, title: "\(a.title) for \(place.name)",
                           message: String(firstParagraph.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)),
                           priority: priority, tags: [a.kind == .warning ? "warning" : "cloud_with_lightning"]))
    }
}

@MainActor func checkForecast(_ place: Place) async {
    let rainOn = flag("PUSH_RAIN"), frostOn = flag("PUSH_FROST")
    guard rainOn || frostOn,
          let forecast = await attempt({ try await forecastProvider.forecast(for: place.coordinate) }) else { return }

    if rainOn {
        let last = state.rain[place.name].map { Date(timeIntervalSince1970: $0) }
        if let nowcast = RainHeadsUp.shouldNotify(forecast.nowcast(at: now), lastNotified: last, now: now),
           ModelAgreement.wetAgrees(forecast.hourly, now: now) {
            state.rain[place.name] = now.timeIntervalSince1970
            let snow = nowcast.kind == .snow
            await send(Message(topic: place.topic, title: "\(snow ? "Snow" : "Rain") on the way in \(place.name)",
                               message: RainHeadsUp.body(nowcast, at: now, timeZone: forecast.timeZone),
                               priority: 3, tags: [snow ? "snowflake" : "umbrella"]))
        }
    }

    if frostOn {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let hour = calendar.component(.hour, from: now)
        let today = AccuracyLog.dayString(now, timeZone: forecast.timeZone)
        if (14...22).contains(hour), state.frost[place.name] != today,
           let frost = ModelAgreement.frost(forecast, now: now) {
            state.frost[place.name] = today
            let f = DateFormatter()
            f.timeZone = forecast.timeZone
            f.dateFormat = "h a"
            await send(Message(topic: place.topic, title: "Frost likely tonight in \(place.name)",
                               message: "\(frost.agreeing) of \(frost.total) forecast models drop to 0°C or below by about \(f.string(from: frost.time)). Cover plants and watch for icy spots.",
                               priority: 3, tags: ["snowflake"]))
        }
    }
}

print("## Weather push check, \(ISO8601DateFormatter().string(from: now))")
print("Places: \(places.map(\.name).joined(separator: ", "))\(firstRun ? " (first run)" : "")")
for place in places {
    await checkAlerts(place)
    await checkForecast(place)
}

do {
    try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: statePath))
} catch {
    print("Couldn't save state: \(error.localizedDescription)")
}
