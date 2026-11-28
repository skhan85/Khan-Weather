import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How old the newest radar scan is, so the radar card can say "Latest scan 6 min ago" and warn
/// when the radar is running late (the map and the "now" sky are then older than they look).
public enum RadarFreshness {
    public enum Level: Equatable, Sendable {
        /// Up to 15 minutes: Environment Canada publishes every 6 minutes a few minutes late,
        /// RainViewer every 10, so this is normal.
        case fresh
        /// 16 to 30 minutes: a frame or two missing.
        case late
        /// Over 30 minutes: rain may have moved well away from where the map shows it.
        case stale
    }

    public static func level(latest: Date, now: Date = Date()) -> Level {
        let minutes = now.timeIntervalSince(latest) / 60
        if minutes <= 15 { return .fresh }
        if minutes <= 30 { return .late }
        return .stale
    }

    /// "6 min ago", "1 hr 10 min ago", "Just now".
    public static func age(latest: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int((now.timeIntervalSince(latest) / 60).rounded()))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr ago" : "\(h) hr \(m) min ago"
    }

    /// The line under the radar card.
    public static func text(latest: Date, now: Date = Date()) -> String {
        let ago = age(latest: latest, now: now)
        switch level(latest: latest, now: now) {
        case .fresh: return "Latest radar scan \(ago)."
        case .late: return "Radar is running late: latest scan \(ago)."
        case .stale: return "Radar is behind: latest scan \(ago), so rain may have moved since."
        }
    }

    /// Frame times on the loop, measured from the clock rather than from the newest frame, so the
    /// newest frame doesn't read "Now" when it's 20 minutes old. "Now" within 2 minutes.
    public static func relative(_ time: Date, now: Date = Date()) -> String {
        let minutes = Int((time.timeIntervalSince(now) / 60).rounded())
        if abs(minutes) <= 2 { return "Now" }
        return minutes < 0 ? "\(-minutes) min ago" : "in \(minutes) min"
    }

    // MARK: Environment Canada's newest frame

    /// The newest Environment Canada radar frame, from the time GeoMet stamps on the reading at
    /// this spot (one small request; the full capabilities document can take a minute). Nil if
    /// GeoMet doesn't answer within `timeout`.
    public static func latestECCCFrame(at coordinate: Coordinate, timeout: Double = 6,
                                       provider: ECCCRadarProvider = ECCCRadarProvider()) async -> Date? {
        await Deadline.run(timeout) { try? await provider.reading("RADAR_1KM_RRAI", at: coordinate)?.time }
    }

    /// Environment Canada's loop: the last hour of frames, every 6 minutes, ending at `latest`
    /// (the newest published frame) or, if that's unknown, at the usual guess of 9 minutes ago.
    public static func ecccFrameTimes(latest: Date?, hours: Int = 1, now: Date = Date()) -> [Date] {
        let six: TimeInterval = 6 * 60
        let guess = ((now.timeIntervalSince1970 - 9 * 60) / six).rounded(.down) * six
        // A newest frame from the future or over 3 hours old is a bad answer; use the guess.
        let end: TimeInterval
        if let latest, latest <= now.addingTimeInterval(60), now.timeIntervalSince(latest) < 3 * 3600 {
            end = latest.timeIntervalSince1970
        } else {
            end = guess
        }
        let step = hours > 1 ? 2 * six : six
        // GeoMet keeps three hours; stay a frame inside it measured from now, not from `end`.
        let oldestAllowed = now.timeIntervalSince1970 - 3 * 3600 + six
        let count = hours > 1 ? Int((Double(hours) * 3600 - six) / step) + 1 : 10
        return (0..<count).reversed()
            .map { end - Double($0) * step }
            .filter { $0 >= oldestAllowed }
            .map { Date(timeIntervalSince1970: $0) }
    }
}
