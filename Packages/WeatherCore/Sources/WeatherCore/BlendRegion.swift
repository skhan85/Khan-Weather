import Foundation

/// Where the blend's weights come from: one set per part of the world.
///
/// Each region's weights were fitted on hourly readings at its own airports
/// (tools/score_regions.py, about 65 airports on six continents), and kept only where they beat
/// the worldwide weights at airports left out of the fit; otherwise the region uses the worldwide
/// set (`fallback`). `useBlend` is false where Open-Meteo's own best match scored better than the
/// blend, and the app then shows best match there. The numbers live in BlendRegionTable.swift,
/// generated from Packages/WeatherCore/blend-regions.json (the same table for any port of the app).
public struct BlendRegion: Equatable, Sendable {
    /// latitude latMin...latMax, longitude lonMin...lonMax (degrees east).
    public struct Box: Equatable, Sendable {
        public var latMin, latMax, lonMin, lonMax: Double
        init(_ latMin: Double, _ latMax: Double, _ lonMin: Double, _ lonMax: Double) {
            (self.latMin, self.latMax, self.lonMin, self.lonMax) = (latMin, latMax, lonMin, lonMax)
        }
        func contains(_ c: Coordinate) -> Bool {
            (latMin...latMax).contains(c.latitude) && (lonMin...lonMax).contains(c.longitude)
        }
    }

    public var id: String
    public var name: String
    public var boxes: [Box]
    /// Whether the blend beat best match here (else the app keeps best match's temperatures).
    public var useBlend: Bool
    /// Weights by forecast day, centred at lead hours 12, 36, 60, 84, 108 and 132.
    public var byDay: [[WeatherModel: Double]]

    /// The region for a spot: the first whose box holds it, else the worldwide weights.
    public static func at(_ coordinate: Coordinate) -> BlendRegion {
        regions.first { $0.boxes.contains { $0.contains(coordinate) } } ?? fallback
    }

    /// The region of the app's default spot (Toronto); used when a caller names none.
    public static let home = at(.fallback)
}
