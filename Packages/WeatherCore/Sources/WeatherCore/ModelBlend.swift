import Foundation

/// Khan Weather's own temperature forecast: a weighted average of several models.
///
/// The weights come from scoring 12 months of archived forecasts (Nov 2025 to Oct 2026) against
/// hourly readings at Toronto Pearson and Hamilton Airport (tools/score_models.py), fitted for the
/// lowest error on held-out days. Each row is one forecast day; hours in between are interpolated
/// so the curve doesn't jump. What the scoring found:
/// - Today (first 24 h): NOAA's HRRR/GFS, which update every hour, are far ahead.
/// - From tomorrow: ECMWF's AI model (AIFS) is the most accurate single model and nearly unbiased,
///   rising from about a quarter of the blend tomorrow to half by day 6; GFS, ICON and UKMO follow.
/// A model with no value for an hour (out of range or out of its area) is skipped.
public enum ModelBlend {
    public static let members: [WeatherModel] = [
        .canadaHighRes, .usHighRes, .canada, .europe, .europeAI, .germany, .uk, .us,
    ]

    /// Weights by forecast day, centred at lead hours 12, 36, 60, 84, 108 and 132.
    static let byDay: [[WeatherModel: Double]] = [
        [.usHighRes: 0.45, .us: 0.32, .germany: 0.12, .uk: 0.08, .europe: 0.03],
        [.europeAI: 0.28, .germany: 0.22, .uk: 0.185, .canadaHighRes: 0.12, .canada: 0.10, .europe: 0.04,
         .usHighRes: 0.025, .us: 0.025],
        [.europeAI: 0.35, .us: 0.23, .germany: 0.18, .uk: 0.125, .europe: 0.075, .canada: 0.04],
        [.europeAI: 0.43, .us: 0.235, .uk: 0.11, .germany: 0.095, .europe: 0.085, .canada: 0.045],
        [.europeAI: 0.47, .us: 0.23, .uk: 0.125, .europe: 0.075, .germany: 0.07, .canada: 0.03],
        [.europeAI: 0.49, .europe: 0.165, .us: 0.15, .uk: 0.08, .germany: 0.06, .canada: 0.055],
    ]
    /// How many hours ahead a live PWS reading dynamically re-weights the models.
    static let liveWeightHours: Double = 6
    
    /// The weight of `model` at `leadHours` from now.
    static func weight(_ model: WeatherModel, leadHours: Double) -> Double {
        let x = min(max((leadHours - 12) / 24, 0), Double(byDay.count - 1))
        let i = Int(x), j = min(i + 1, byDay.count - 1), f = x - Double(i)
        return (byDay[i][model] ?? 0) * (1 - f) + (byDay[j][model] ?? 0) * f
    }

    /// Weighted average of the models that have a value; nil if none do. If only models weighted
    /// zero at this range have a value (say only GEM came back today), their plain average is used.
    /// For lead hours 0...6, when a live PWS temperature and current model temperatures are supplied,
    /// combines the static `byDay` prior with an inverse-squared-error weight against the PWS.
    public static func blend(_ values: [WeatherModel: Double],
                             leadHours: Double,
                             observedTemperature: Double? = nil,
                             currentModelTemps: [WeatherModel: Double]? = nil) -> Double? {
        let present = values.filter { members.contains($0.key) }
        guard !present.isEmpty else { return nil }

        let liveShare: Double
        if observedTemperature != nil, let currentModelTemps, !currentModelTemps.isEmpty,
           leadHours >= -1, leadHours <= liveWeightHours {
            liveShare = max(0, min(1, 1 - max(leadHours, 0) / liveWeightHours))
        } else {
            liveShare = 0
        }

        var errorWeights: [WeatherModel: Double] = [:]
        if liveShare > 0, let obs = observedTemperature, let currentModelTemps {
            var invTotal = 0.0
            for model in present.keys {
                let priorFloor = max(weight(model, leadHours: leadHours), 0.04)
                if let nowTemp = currentModelTemps[model] {
                    let err = abs(nowTemp - obs)
                    let invSq = priorFloor / (err * err + 0.5)
                    errorWeights[model] = invSq
                    invTotal += invSq
                }
            }
            if invTotal > 0 {
                for (m, w) in errorWeights { errorWeights[m] = w / invTotal }
            }
        }

        var sum = 0.0, total = 0.0
        for (model, value) in present {
            let prior = weight(model, leadHours: leadHours)
            let w: Double
            if liveShare > 0, let dyn = errorWeights[model] {
                w = prior * (1 - liveShare) + dyn * liveShare
            } else {
                w = prior
            }
            sum += value * w
            total += w
        }
        if total > 0 { return sum / total }
        return present.values.reduce(0, +) / Double(present.count)
    }
}
