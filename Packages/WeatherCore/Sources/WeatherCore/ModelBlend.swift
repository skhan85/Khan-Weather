import Foundation

/// Khan Weather's own temperature forecast: a weighted average of several models.
///
/// For the next day or two the high-resolution models (Environment Canada's HRDPS at 2.5 km and
/// NOAA's HRRR at 3 km) count most, because they resolve the lake, the escarpment and local
/// winds. Further out they stop, and the global models take over with ECMWF, usually the most
/// accurate, counting most. Weights shift gradually between 36 and 60 hours so the curve
/// doesn't jump. A model with no value for an hour (out of range or out of its area) is skipped.
public enum ModelBlend {
    public static let members: [WeatherModel] = [
        .canadaHighRes, .usHighRes, .canada, .europe, .germany, .uk, .us,
    ]

    static let shortRange: [WeatherModel: Double] = [
        .canadaHighRes: 3, .usHighRes: 2.5, .canada: 1.5, .europe: 1.5, .germany: 1, .uk: 1, .us: 0.5,
    ]
    static let longRange: [WeatherModel: Double] = [
        .europe: 3, .canada: 2, .germany: 1.5, .uk: 1.5, .us: 1, .canadaHighRes: 1, .usHighRes: 1,
    ]

    /// The weight of `model` at `leadHours` from now.
    static func weight(_ model: WeatherModel, leadHours: Double) -> Double {
        let f = min(max((leadHours - 36) / 24, 0), 1)   // 0 up to 36 h, 1 from 60 h
        return (shortRange[model] ?? 0) * (1 - f) + (longRange[model] ?? 0) * f
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
