import Foundation

/// Khan Weather's own temperature forecast: a weighted average of several models.
///
/// The weights come from scoring 12 months of archived forecasts (Nov 2025 to Oct 2026) against
/// hourly readings at Toronto Pearson and Hamilton Airport (tools/score_models.py), fitted for the
/// lowest error on held-out days. Each row is one forecast day; hours in between are interpolated
/// so the curve doesn't jump. What the scoring found:
/// - Today (first 24 h): NOAA's HRRR/GFS, which update every hour, are far ahead.
/// - Tomorrow: ICON, UKMO and the Canadian models count most.
/// - Days 3 to 5: GFS leads, with ECMWF, ICON and UKMO close behind.
/// - Day 6 on: ECMWF leads.
/// A model with no value for an hour (out of range or out of its area) is skipped.
public enum ModelBlend {
    public static let members: [WeatherModel] = [
        .canadaHighRes, .usHighRes, .canada, .europe, .germany, .uk, .us,
    ]

    /// Weights by forecast day, centred at lead hours 12, 36, 60, 84, 108 and 132.
    static let byDay: [[WeatherModel: Double]] = [
        [.usHighRes: 0.45, .us: 0.32, .germany: 0.12, .uk: 0.08, .europe: 0.03],
        [.germany: 0.27, .uk: 0.21, .canadaHighRes: 0.15, .europe: 0.15, .canada: 0.13, .usHighRes: 0.05, .us: 0.05],
        [.us: 0.27, .germany: 0.25, .uk: 0.18, .europe: 0.17, .canada: 0.13],
        [.us: 0.31, .europe: 0.20, .germany: 0.19, .uk: 0.16, .canada: 0.14],
        [.us: 0.33, .europe: 0.19, .uk: 0.18, .germany: 0.16, .canada: 0.14],
        [.europe: 0.34, .us: 0.26, .canada: 0.15, .uk: 0.15, .germany: 0.10],
    ]

    /// The weight of `model` at `leadHours` from now.
    static func weight(_ model: WeatherModel, leadHours: Double) -> Double {
        let x = min(max((leadHours - 12) / 24, 0), Double(byDay.count - 1))
        let i = Int(x), j = min(i + 1, byDay.count - 1), f = x - Double(i)
        return (byDay[i][model] ?? 0) * (1 - f) + (byDay[j][model] ?? 0) * f
    }

    /// Weighted average of the models that have a value; nil if none do.
    public static func blend(_ values: [WeatherModel: Double], leadHours: Double) -> Double? {
        var sum = 0.0, total = 0.0
        for (model, value) in values {
            let w = weight(model, leadHours: leadHours)
            guard w > 0 else { continue }
            sum += value * w
            total += w
        }
        return total > 0 ? sum / total : nil
    }
}
