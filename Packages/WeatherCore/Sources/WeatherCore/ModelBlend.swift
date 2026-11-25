import Foundation

/// Khan Weather's own temperature forecast: a weighted average of several models.
///
/// The weights depend on where you are (BlendRegion): each part of the world has its own set,
/// fitted on hourly readings at its airports (tools/score_regions.py), with a worldwide set for
/// everywhere else. Each row is one forecast day; hours in between are interpolated so the curve
/// doesn't jump. A model with no value for an hour (out of range or out of its area, like HRRR
/// outside North America) is skipped and the others share its weight.
/// The first weights (Pearson and Hamilton only, tools/score_models.py, score_leads.py,
/// score_forward.py) are kept in tools/score_regions.py as the "milton" baseline it scores against.
public enum ModelBlend {

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

    /// The weight of `model` at `leadHours` from now, in `region`.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _regional: [String: [WeatherModel: Double]] = [:]

    private static let synopticModels: Set<WeatherModel> = [
        .europeAI, .europe, .germany, .canada, .us, .uk,
    ]

    static func gridKey(_ coordinate: Coordinate) -> String {
        let lat = Int((coordinate.latitude * 2).rounded())
        let lon = Int((coordinate.longitude * 2).rounded())
        return "\(lat),\(lon)"
    }

    public static func setRegionalWeights(_ raw: [String: Double], for coordinate: Coordinate? = nil) {
        let map: [String: WeatherModel] = [
            "europeAI": .europeAI, "europe": .europe, "germany": .germany,
            "canada": .canada, "us": .us, "uk": .uk,
            "canadaHighRes": .canadaHighRes, "usHighRes": .usHighRes,
        ]
        var parsed: [WeatherModel: Double] = [:]
        for (k, v) in raw where v > 0 { if let m = map[k] { parsed[m] = v } }
        guard !parsed.isEmpty else { return }
        let key = coordinate.map(gridKey) ?? "default"
        lock.lock(); _regional[key] = parsed; lock.unlock()
    }

    private static func interpolatedPrior(_ model: WeatherModel, leadHours: Double, byDay: [[WeatherModel: Double]]) -> Double {
        let x = min(max((leadHours - 12) / 24, 0), Double(byDay.count - 1))
        let i = Int(x), j = min(i + 1, byDay.count - 1), f = x - Double(i)
        return (byDay[i][model] ?? 0) * (1 - f) + (byDay[j][model] ?? 0) * f
    }

    static func weight(_ model: WeatherModel, leadHours: Double, region: BlendRegion = .home,
                       coordinate: Coordinate? = nil) -> Double {
        let byDay = region.byDay
        guard !byDay.isEmpty else { return 1 }
        let prior = interpolatedPrior(model, leadHours: leadHours, byDay: byDay)
        lock.lock()
        let regMap = coordinate.flatMap { _regional[gridKey($0)] } ?? _regional["default"]
        lock.unlock()
        // Regional relay weights are scored across synoptic models; mix 50/50 with the regional
        // prior across all lead times while scaling non-synoptic models by 0.5 so total weight stays balanced.
        if let regMap {
            let regTotal = regMap.values.reduce(0, +)
            if regTotal > 0 {
                if let reg = regMap[model], synopticModels.contains(model) {
                    return 0.5 * prior + 0.5 * (reg / regTotal)
                }
                return 0.5 * prior
            }
        }
        return prior
    }

    /// Weighted average of the models that have a value; nil if none do. If only models weighted
    /// zero at this range have a value (say only GEM came back today), their plain average is used.
    /// For lead hours 0...6, when a live PWS temperature and current model temperatures are supplied,
    /// combines the static `byDay` prior with an inverse-squared-error weight against the PWS.
    public static func blend(_ values: [WeatherModel: Double],
                             leadHours: Double,
                             region: BlendRegion = .home,
                             observedTemperature: Double? = nil,
                             currentModelTemps: [WeatherModel: Double]? = nil,
                             coordinate: Coordinate? = nil) -> Double? {
        let present = values.filter { region.models.contains($0.key) }
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
                let priorFloor = max(weight(model, leadHours: leadHours, region: region, coordinate: coordinate), 0.04)
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
            let prior = weight(model, leadHours: leadHours, region: region, coordinate: coordinate)
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

    /// Precipitation & rain/snow skill weights: prioritize high-res & physics NWP over AI/coarse models.
    static func precipitationWeight(_ model: WeatherModel) -> Double {
        switch model {
        case .canadaHighRes, .usBlend, .europeHighRes: return 0.18
        case .usHighRes: return 0.16
        case .europe: return 0.14
        case .germany, .france, .netherlands, .denmark: return 0.12
        case .canada: return 0.10
        case .us, .uk, .bestMatch: return 0.08
        case .europeAI: return 0.04
        case .blend: return 0
        }
    }

    /// Weighted ensemble precipitation/snowfall mean across blend models using precipitation weights.
    static func blendedPrecipitation(_ values: [WeatherModel: Double],
                                     leadHours: Double,
                                     region: BlendRegion = .home,
                                     coordinate: Coordinate? = nil) -> Double? {
        let present = values.filter { region.models.contains($0.key) }
        guard present.count >= 3 else { return nil }
        var sum = 0.0, total = 0.0
        for (model, value) in present {
            let w = precipitationWeight(model)
            sum += max(0, value) * w
            total += w
        }
        if total > 0 { return sum / total }
        return present.values.map { max(0, $0) }.reduce(0, +) / Double(present.count)
    }

    // MARK: Daily high and low

    /// Added to the warmest blended hour for the day's high. A day's real high usually falls
    /// between two hours: at six ECCC stations around Milton (Nov 2025-Oct 2026,
    /// tools/score_extremes.py) the warmest hourly reading was 0.27-0.42° below the recorded high
    /// at every one of them, and the app's highs ran about 0.5-0.75° low. Only this between-hours
    /// part is added, since it was the same everywhere; held out per station it cut today's
    /// high error from 1.02 to about 0.9°.
    public static let highAllowance: Double = 0.4
    /// Taken off the coldest blended hour for the low: the coldest hourly reading was 0.37-0.66°
    /// above the recorded low at the same stations.
    public static let lowAllowance: Double = 0.5

    // MARK: Rain or snow

    /// A model hour counts as wet for its rain-or-snow call from this much (mm).
    static let typeWetMm: Double = 0.05

    /// Rain or snow this hour, from the blend's models: snow when at least half of the wet
    /// models call snow (a model calls snow when its snowfall, as water at cm × 0.7, is at least
    /// half its precipitation); with no wet model, snow at or below 1 °C. A blend at 3° or warmer
    /// is always rain and at -2° or colder always snow.
    ///
    /// Scored against what the Toronto Pearson and Hamilton airport observers reported in about
    /// 2,000 rain and snow hours (Nov 2025-Apr 2026, tools/score_ptype.py), this was right 97% of
    /// the time today and 95% two days out, against 95% and 90% for Open-Meteo's single
    /// best-match model, which the app used before.
    /// Weighted snow share among wet models (0...1), or nil when no model is wet.
    static func precipitationSnowShare(temperature: Double,
                                       precipitation: [WeatherModel: Double],
                                       snowfall: [WeatherModel: Double]) -> Double? {
        if temperature >= 3 { return 0 }
        if temperature <= -2 { return 1 }
        var wetWeight = 0.0, snowWeight = 0.0
        for (m, p) in precipitation where p >= typeWetMm {
            guard let s = snowfall[m] else { continue }
            let w = max(0.01, precipitationWeight(m))
            wetWeight += w
            if s / 0.7 >= 0.5 * p { snowWeight += w }
        }
        guard wetWeight > 0 else { return nil }
        return snowWeight / wetWeight
    }

    public static func precipitationType(temperature: Double,
                                         precipitation: [WeatherModel: Double],
                                         snowfall: [WeatherModel: Double]) -> PrecipitationKind {
        if temperature >= 3 { return .rain }
        if temperature <= -2 { return .snow }
        if let share = precipitationSnowShare(temperature: temperature, precipitation: precipitation, snowfall: snowfall) {
            if share >= 0.7 { return .snow }
            if share <= 0.3 { return .rain }
            return .mixed
        }
        return temperature <= 1 ? .snow : .rain
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
