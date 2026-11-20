import Foundation

/// Khan Weather's own temperature forecast: a weighted average of several models.
///
/// The weights come from scoring 12 months of archived forecasts (Nov 2025 to Oct 2026) against
/// hourly readings at Toronto Pearson and Hamilton Airport (tools/score_models.py), fitted for the
/// lowest error on held-out days. Each row is one forecast day; hours in between are interpolated
/// so the curve doesn't jump. What the scoring found:
/// - Today (first 24 h): no single model. The archive's "today" is each model's latest run, which
///   for hourly-updated HRRR is a 1-2 hour forecast, so it made HRRR look far ahead. Scored at the
///   lead times the app really uses (tools/score_leads.py, Apr-Oct 2026 single runs; and
///   tools/score_forward.py, the live log from 15 Nov), HRRR/GFS ran cold and the old weights
///   (77% on them) were worse than a plain average; ICON, ECMWF and GEM did best.
/// - From tomorrow: ECMWF's AI model (AIFS) is the most accurate single model and nearly unbiased,
///   rising from about a quarter of the blend tomorrow to half by day 6; GFS, ICON and UKMO follow.
/// A model with no value for an hour (out of range or out of its area) is skipped.
public enum ModelBlend {
    public static let members: [WeatherModel] = [
        .canadaHighRes, .usHighRes, .canada, .europe, .europeAI, .germany, .uk, .us,
    ]

    /// Weights by forecast day, centred at lead hours 12, 36, 60, 84, 108 and 132.
    static let byDay: [[WeatherModel: Double]] = [
        // Today. GFS is left out: for the first two days Open-Meteo's "GFS" is the same HRRR series.
        [.germany: 0.30, .europe: 0.20, .usHighRes: 0.15, .canada: 0.15, .uk: 0.10, .europeAI: 0.10],
        [.europeAI: 0.28, .germany: 0.22, .uk: 0.185, .canadaHighRes: 0.12, .canada: 0.10, .europe: 0.04,
         .usHighRes: 0.025, .us: 0.025],
        [.europeAI: 0.35, .us: 0.23, .germany: 0.18, .uk: 0.125, .europe: 0.075, .canada: 0.04],
        [.europeAI: 0.43, .us: 0.235, .uk: 0.11, .germany: 0.095, .europe: 0.085, .canada: 0.045],
        [.europeAI: 0.47, .us: 0.23, .uk: 0.125, .europe: 0.075, .germany: 0.07, .canada: 0.03],
        [.europeAI: 0.49, .europe: 0.165, .us: 0.15, .uk: 0.08, .germany: 0.06, .canada: 0.055],
    ]
    /// How many hours ahead a live station reading re-weights the models.
    static let liveWeightHours: Double = 6
    /// Added to each model's squared error (°C²) before inverting it. A single reading wobbles by
    /// a degree or so, so a model 0.3° off gets about 1.6× the weight of one 1.5° off, not 5×.
    static let errorSoftening: Double = 2

    /// A local station reading that re-weights the first hours of the blend.
    public struct Anchor: Equatable, Sendable {
        public var temperature: Double
        public var time: Date
        public init(temperature: Double, time: Date) {
            self.temperature = temperature
            self.time = time
        }
    }

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
                    let invSq = priorFloor / (err * err + errorSoftening)
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

    // MARK: Chance of rain

    /// A model hour counts as wet from this much precipitation (mm).
    static let wetHourMm: Double = 0.2
    /// A model day counts as wet from this much (mm), as at ECCC's "measurable" day.
    static let wetDayMm: Double = 0.5
    /// Fewest models for their share to count.
    static let minModelsForChance = 4

    /// Open-Meteo's hourly chance averaged with the share of blend models that are wet that hour.
    ///
    /// Scored over Nov 2025-Oct 2026 against the hourly gauges at Hamilton RBG and Guelph
    /// (tools/score_precip.py, 17,000 hours per lead day), the half-and-half mix had a lower
    /// Brier score than Open-Meteo's chance at every lead: 4% better today, 12% on days 3-4.
    public static func hourlyChance(openMeteo: Double?, wet: Int, of count: Int) -> Double? {
        guard count >= minModelsForChance else { return openMeteo }
        let share = 100 * Double(wet) / Double(count)
        guard let openMeteo else { return share.rounded() }
        return (0.5 * openMeteo + 0.5 * share).rounded()
    }

    /// Open-Meteo's chance for the day mixed with the share of models whose day total is wet.
    ///
    /// Scored on 1,445 days at five ECCC stations around Milton (tools/score_precip.py), Open-Meteo's
    /// daily chance runs far too low (days it gave 20-30% were wet half the time). Mixing in the
    /// models' share cut the Brier score by about 30% today and tomorrow (best with 3/4 share) and
    /// 15-20% on days 3-6 (best half and half).
    public static func dailyChance(openMeteo: Double?, wet: Int, of count: Int, dayIndex: Int) -> Double? {
        guard count >= minModelsForChance else { return openMeteo }
        let share = 100 * Double(wet) / Double(count)
        guard let openMeteo else { return share.rounded() }
        let w = dayIndex <= 1 ? 0.75 : 0.5
        return ((1 - w) * openMeteo + w * share).rounded()
    }
}
