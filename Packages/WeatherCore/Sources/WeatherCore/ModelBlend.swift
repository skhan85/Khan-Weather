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
        public var isHomeStation: Bool
        public init(temperature: Double, time: Date, isHomeStation: Bool = false) {
            self.temperature = temperature
            self.time = time
            self.isHomeStation = isHomeStation
        }
    }

    /// The weight of `model` at `leadHours` from now, in `region`.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _regional: [String: [WeatherModel: Double]] = [:]
    nonisolated(unsafe) private static var _diurnalBias: [String: [Double]] = [:]
    nonisolated(unsafe) private static var _learned: [String: LearnedCorrections] = [:]

    private static let synopticModels: Set<WeatherModel> = [
        .europeAI, .europe, .germany, .canada, .us, .uk,
    ]

    static func gridKey(_ coordinate: Coordinate) -> String {
        let lat = Int((coordinate.latitude * 2).rounded())
        let lon = Int((coordinate.longitude * 2).rounded())
        return "\(lat),\(lon)"
    }

    static func spotKey(_ coordinate: Coordinate) -> String {
        let lat = Int((coordinate.latitude * 10).rounded())
        let lon = Int((coordinate.longitude * 10).rounded())
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

    /// Registers a 3-hour UTC diurnal bias curve (8 bins covering 00..21Z; positive = models run warm).
    public static func setDiurnalBias(_ bias3h: [Double], for coordinate: Coordinate? = nil) {
        guard bias3h.count == 8, bias3h.allSatisfy(\.isFinite) else { return }
        let key = coordinate.map(spotKey) ?? "default"
        lock.lock(); _diurnalBias[key] = bias3h; lock.unlock()
    }

    /// Registers what the relay learned at this place (`RelayExtrasProvider.learned`). A proven
    /// temperature correction takes the place of the relay's diurnal bias for the spot: both are
    /// measured against the same uncorrected blend, so using both would correct twice.
    public static func setLearned(_ learned: LearnedCorrections, for coordinate: Coordinate) {
        lock.lock(); _learned[spotKey(coordinate)] = learned; lock.unlock()
    }

    public static func learned(for coordinate: Coordinate) -> LearnedCorrections? {
        lock.lock(); defer { lock.unlock() }
        return _learned[spotKey(coordinate)]
    }

    /// The learned multiplier on the chance of rain here, 1 when nothing is proven.
    static func learnedPopFactor(for coordinate: Coordinate) -> Double {
        guard let r = learned(for: coordinate)?.rain, r.enabled, let f = r.pop_factor, f.isFinite else { return 1 }
        return min(max(f, 0.5), 1.6)
    }

    static func liveShare(leadHours: Double,
                          observedTemperature: Double?,
                          currentModelTemps: [WeatherModel: Double]?) -> Double {
        guard observedTemperature != nil, let currentModelTemps, !currentModelTemps.isEmpty,
              leadHours >= -1, leadHours <= liveWeightHours else { return 0 }
        return max(0, min(1, 1 - max(leadHours, 0) / liveWeightHours))
    }

    /// Smoothly interpolated local diurnal bias (°C to subtract from model temperatures) at `epoch`.
    static func diurnalBias(at epoch: Double, leadHours: Double, coordinate: Coordinate? = nil) -> Double {
        lock.lock()
        let learnedBins = coordinate.flatMap { _learned[spotKey($0)]?.temperature?.provenBins }
        let bins = learnedBins ?? coordinate.flatMap { _diurnalBias[spotKey($0)] } ?? _diurnalBias["default"]
        lock.unlock()
        guard let bins, bins.count == 8 else { return 0 }
        let secOfDay = ((epoch.truncatingRemainder(dividingBy: 86400)) + 86400).truncatingRemainder(dividingBy: 86400)
        let pos = (secOfDay / 3600.0 - 1.5) / 3.0
        let lo = Int(floor(pos))
        let frac = pos - Double(lo)
        let i0 = ((lo % 8) + 8) % 8
        let i1 = (i0 + 1) % 8
        let raw = bins[i0] * (1 - frac) + bins[i1] * frac
        let leadScale = leadHours <= 120 ? 1.0 : max(0.6, 1.0 - 0.4 * (leadHours - 120) / 96)
        return raw * leadScale
    }

    /// The weight from the region's table at `leadHours`: the short-range bands for the next 12
    /// hours (straight lines between their centres, then into day 0 at hour 12), the day rows after.
    static func tablePrior(_ model: WeatherModel, leadHours: Double, region: BlendRegion) -> Double {
        let sr = region.shortRange
        let centres = BlendRegion.shortRangeCentres
        guard sr.count == centres.count, !region.byDay.isEmpty, leadHours < 12 else {
            return interpolatedPrior(model, leadHours: leadHours, byDay: region.byDay)
        }
        let xs = centres + [12]
        let ys = sr.map { $0[model] ?? 0 } + [region.byDay[0][model] ?? 0]
        if leadHours <= xs[0] { return ys[0] }
        for k in 1..<xs.count where leadHours <= xs[k] {
            let f = (leadHours - xs[k - 1]) / (xs[k] - xs[k - 1])
            return ys[k - 1] * (1 - f) + ys[k] * f
        }
        return ys[ys.count - 1]
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
        let prior = tablePrior(model, leadHours: leadHours, region: region)
        lock.lock()
        let regMap = coordinate.flatMap { _regional[gridKey($0)] } ?? _regional["default"]
        lock.unlock()
        // Regional relay weights are scored across synoptic models; mix 50/50 with the regional
        // prior across all lead times while scaling non-synoptic models by 0.5 so total weight stays balanced.
        if let regMap {
            let regTotal = regMap.reduce(0.0) { acc, kv in
                acc + (synopticModels.contains(kv.key) && region.models.contains(kv.key) ? kv.value : 0)
            }
            if regTotal > 0 {
                if let reg = regMap[model], synopticModels.contains(model), region.models.contains(model) {
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

        let liveShare = liveShare(leadHours: leadHours,
                                  observedTemperature: observedTemperature,
                                  currentModelTemps: currentModelTemps)

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
        case .europe, .japan: return 0.14
        case .germany, .france, .netherlands, .denmark, .norway: return 0.12
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

    /// Added to the warmest blended hour for the daily high. The real high falls between hours,
    /// and the blend (an average) runs below each model's own peak. Scored worldwide against
    /// official daily highs (NOAA GHCN-Daily, tools/score_highlow.py, 34 airports in North America,
    /// Europe and Australia/NZ, Jan-Oct 2026): the blend's high needed +0.9 on average (median
    /// +1.0), about the same in every region. Fitted on the other airports and scored on the one
    /// left out, +0.9 cut tomorrow's high error from 1.08 to 0.97 (day after: 1.20 to 1.09) and
    /// helped in all four regions. Was 0.4, fitted at six Ontario stations only.
    /// The high can sit a degree above the warmest hour shown; that's where real highs land.
    public static let highAllowance: Double = 0.9
    /// Taken off the coldest blended hour for the low: the coldest hourly reading was 0.37-0.66°
    /// above the recorded low at the same stations. The worldwide check (tools/score_highlow.py)
    /// agreed: 0.5 scored as well as a fitted constant in every region, so it stays.
    public static let lowAllowance: Double = 0.5
    /// Weight and horizon for blending Google Weather hourly temperatures over the regional NWP blend.
    public static let googleWeight: Double = 0.15
    public static let googleHorizonHours: Double = 48
    /// Distance-tapered weight and horizon for DWD MOSMIX calibrated WMO station forecasts (< 25 km).
    public static let mosmixWeight: Double = 0.12
    public static let mosmixHorizonHours: Double = 72

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

/// What the relay learned about the forecast at one place (GET /v1/learned, tools/learn/learner.py):
/// the blend's own error there, by 3-hour block of the day, and how often it really rains when the
/// chance says it might. A correction is `enabled` only once it has beaten the plain forecast on the
/// last 14 days, each day corrected with what was known before it.
public struct LearnedCorrections: Codable, Equatable, Sendable {
    public struct Temperature: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// °C to subtract, 8 blocks of 3 hours from 00 UTC (positive = forecast runs warm here).
        public var bias_3h: [Double]?
        public var mae_raw: Double?
        public var mae_learned: Double?
        public var checked_days: Int?
        public var truth: String?

        var provenBins: [Double]? {
            guard enabled, let b = bias_3h, b.count == 8, b.allSatisfy({ $0.isFinite && abs($0) <= 3 }) else { return nil }
            return b
        }
    }
    public struct Rain: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var pop_factor: Double?
        public var brier_raw: Double?
        public var brier_learned: Double?
        public var wet_hours: Int?
        public var truth: String?
    }
    public var status: String?
    public var days: Int?
    public var temperature: Temperature?
    public var rain: Rain?

    public init(status: String? = nil, days: Int? = nil, temperature: Temperature? = nil, rain: Rain? = nil) {
        self.status = status; self.days = days; self.temperature = temperature; self.rain = rain
    }

    /// One or two plain sentences for the compare screen, e.g. "Learned here over 21 days: forecasts
    /// ran warm overnight, now corrected (checked error 1.4° → 1.1°)."
    public var summary: String {
        let d = days ?? 0
        var parts: [String] = []
        if let t = temperature, t.enabled, let raw = t.mae_raw, let new = t.mae_learned, let bins = t.bias_3h {
            let worst = bins.max { abs($0) < abs($1) } ?? 0
            let way = worst > 0 ? "warm" : "cold"
            let k = UnitSettings.current.temperature == .fahrenheit ? 1.8 : 1.0   // a difference, not a reading
            parts.append(String(format: "temperatures here ran up to %.1f° %@ at some hours, now corrected (checked error %.1f° → %.1f°)",
                                abs(worst) * k, way, raw * k, new * k))
        }
        if let r = rain, r.enabled, let f = r.pop_factor {
            parts.append(f < 1 ? "rain came less often than the chance said, so chances here are scaled down"
                               : "rain came more often than the chance said, so chances here are scaled up")
        }
        if parts.isEmpty {
            return d < 10 ? "Learning this place: \(d) of 10 days so far. Nothing is corrected until it proves itself."
                          : "Checked over \(d) days here: no correction has proven itself yet, so the forecast is left as is."
        }
        return "Learned here over \(d) days: " + parts.joined(separator: "; ") + "."
    }
}
