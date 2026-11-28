import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// "Where is the rain heading": a radar-motion nowcast for the next 90 minutes from RainViewer's
/// radar frames, for where Environment Canada's own extrapolation (relay /v1/nowcast) doesn't
/// reach or says nothing.
///
/// The newest frame and the one about 20 minutes before it (2x2 tiles at zoom 6 around the spot)
/// are lined up to find how far the rain moved; the rain at the spot L minutes ahead is what the
/// newest frame shows that far upstream. tools/radar_motion.py is the same thing in Python, and
/// the GitHub check that scores it against the frames that followed (score-radar-motion.yml).
/// The Android port is android/core/.../RadarMotion.kt.
public enum RadarMotion {
    static let zoom = 6
    static let tile = 256
    /// Half-size of the matching window, in pixels (about 85 km at 45°).
    static let window = 48
    static let maxSpeedKmh = 110.0
    static let minEchoPixels = 20
    static let maxLeadMinutes = 90
    static let stepMinutes = 5
    static let minDBZ = 10.0

    /// A mosaic of radar reflectivity (dBZ, nil where there's no echo), row by row.
    struct Grid {
        var width: Int
        var height: Int
        var dbz: [Double?]
        var rain: [Double]

        init(width: Int, height: Int, dbz: [Double?]) {
            self.width = width
            self.height = height
            self.dbz = dbz
            rain = dbz.map { RadarMotion.rainRate($0) }
        }

        func index(_ x: Int, _ y: Int) -> Int { y * width + x }
    }

    // MARK: Colours and rates

    /// RainViewer's Universal Blue (colour scheme 2) rain colours, dBZ -10...64.
    static let palette: [(dbz: Double, r: Double, g: Double, b: Double)] = {
        let hex = ["636159", "66635a", "69665c", "6c685d", "6f6b5f", "726e61", "757062", "787364",
                   "7c7565", "7f7867", "827b69", "857d6a", "88806c", "8b826d", "8e856f", "928871",
                   "9e9375", "aa9e79", "b6a97e", "c2b482", "cec087", "d2c48b", "d6c88f", "dacc93",
                   "ded097", "88ddee", "6cd1eb", "51c5e8", "36bae5", "1baee2", "00a3e0", "009ad5",
                   "0091ca", "0088bf", "007fb4", "0077aa", "0070a3", "00699c", "006295", "005b8e",
                   "005588", "005180", "004e78", "004a70", "004768", "ffee00", "ffe000", "ffd200",
                   "ffc500", "ffb700", "ffaa00", "ff9f00", "ff9500", "ff8b00", "ff8100", "ff4400",
                   "f23600", "e62800", "d91b00", "cd0d00", "c10000", "a80000", "8f0000", "760000",
                   "5d0000", "ffaaff", "ff9fff", "ff95ff", "ff8bff", "ff81ff", "ff77ff", "ff6cff",
                   "ff62ff", "ff58ff", "ff4eff"]
        return hex.enumerated().map { i, h in
            let v = Int(h, radix: 16)!
            return (Double(i - 10), Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255))
        }
    }()

    /// dBZ for one pixel (straight, not premultiplied, alpha); nil where there's no echo.
    static func dbz(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> Double? {
        guard a >= 16 else { return nil }
        let (R, G, B) = (Double(r), Double(g), Double(b))
        var best = palette[0].dbz, bestD = Double.infinity
        for p in palette {
            let d = (p.r - R) * (p.r - R) + (p.g - G) * (p.g - G) + (p.b - B) * (p.b - B)
            if d < bestD { bestD = d; best = p.dbz }
        }
        return best
    }

    /// Rain rate in mm/h (Marshall-Palmer, Z = 200 R^1.6); 0 below `minDBZ`.
    static func rainRate(_ dbz: Double?) -> Double {
        guard let dbz, dbz >= minDBZ else { return 0 }
        return pow(pow(10, dbz / 10) / 200, 1 / 1.6)
    }

    /// Snowfall in cm/h from the same echo read as snow (Z = 2000 S^2, 1 mm water = 1 cm snow).
    static func snowRate(_ dbz: Double?) -> Double {
        guard let dbz, dbz >= minDBZ else { return 0 }
        return pow(pow(10, dbz / 10) / 2000, 0.5)
    }

    // MARK: Geometry

    static func globalPixel(_ c: Coordinate) -> (x: Double, y: Double) {
        let n = Double(tile) * pow(2, Double(zoom))
        let x = (c.longitude + 180) / 360 * n
        let s = c.latitude * .pi / 180
        let y = (1 - log(tan(s) + 1 / cos(s)) / .pi) / 2 * n
        return (x, y)
    }

    /// The top-left tile of the 2x2 block that keeps the spot near the middle, and the spot's
    /// pixel in that 512x512 mosaic.
    static func tiles(for c: Coordinate) -> (tx: Int, ty: Int, x: Double, y: Double) {
        let p = globalPixel(c)
        let tx = Int((p.x / Double(tile)).rounded()) - 1
        let ty = Int((p.y / Double(tile)).rounded()) - 1
        return (tx, ty, p.x - Double(tx * tile), p.y - Double(ty * tile))
    }

    static func pixelKm(_ c: Coordinate) -> Double {
        40075.016 * cos(c.latitude * .pi / 180) / (Double(tile) * pow(2, Double(zoom)))
    }

    // MARK: Motion

    /// How far the rain moved from `old` to `new`, in pixels per minute; zero when there's too
    /// little rain near the spot to tell, or when no shift lines the frames up better than none.
    static func motion(old: Grid, new: Grid, x cx: Double, y cy: Double, minutes: Double, km: Double) -> (dx: Double, dy: Double) {
        guard minutes > 0, km > 0 else { return (0, 0) }
        let reach = Int((maxSpeedKmh * minutes / 60 / km).rounded(.up))
        let x0 = max(Int(cx) - window, reach), x1 = min(Int(cx) + window, new.width - reach - 1)
        let y0 = max(Int(cy) - window, reach), y1 = min(Int(cy) + window, new.height - reach - 1)
        guard x1 > x0, y1 > y0 else { return (0, 0) }
        let a = new.rain.map { log1p($0) }
        let b = old.rain.map { log1p($0) }
        var echo = 0
        for y in y0..<y1 { for x in x0..<x1 where a[new.index(x, y)] > 0 { echo += 1 } }
        guard echo >= minEchoPixels else { return (0, 0) }
        var best = Double.infinity, bx = 0, by = 0
        var zero: Double?
        for dy in -reach...reach {
            for dx in -reach...reach {
                var sum = 0.0, n = 0
                for y in y0..<y1 {
                    let rowA = y * new.width, rowB = (y - dy) * old.width
                    for x in x0..<x1 {
                        let va = a[rowA + x], vb = b[rowB + x - dx]
                        if va > 0 || vb > 0 { sum += abs(va - vb); n += 1 }
                    }
                }
                guard n >= minEchoPixels else { continue }
                let c = sum / Double(n)
                if dx == 0 && dy == 0 { zero = c }
                if c < best { best = c; bx = dx; by = dy }
            }
        }
        guard best.isFinite else { return (0, 0) }
        if let zero, best > zero * 0.98 { return (0, 0) }
        return (Double(bx) / minutes, Double(by) / minutes)
    }

    /// The 3x3 mean around a point, nil off the edge.
    static func sample(_ values: [Double], width: Int, height: Int, x: Double, y: Double) -> Double? {
        let xi = Int(x.rounded()), yi = Int(y.rounded())
        guard xi >= 1, yi >= 1, xi < width - 1, yi < height - 1 else { return nil }
        var s = 0.0
        for j in -1...1 { for i in -1...1 { s += values[(yi + j) * width + xi + i] } }
        return s / 9
    }

    /// The nowcast at a spot from two frames `minutes` apart (newest at `time`).
    static func nowcast(old: Grid, new: Grid, time: Date, minutes: Double, x: Double, y: Double, km: Double) -> RelayNowcast {
        let v = motion(old: old, new: new, x: x, y: y, minutes: minutes, km: km)
        let snow = new.dbz.map { snowRate($0) }
        let iso = ISO8601DateFormatter()
        var slots: [RelayNowcast.Slot] = []
        for lead in stride(from: 0, through: maxLeadMinutes, by: stepMinutes) {
            let L = Double(lead)
            let sx = x - v.dx * L, sy = y - v.dy * L
            guard let r = sample(new.rain, width: new.width, height: new.height, x: sx, y: sy),
                  let s = sample(snow, width: new.width, height: new.height, x: sx, y: sy) else { break }
            let t = time.addingTimeInterval(L * 60)
            slots.append(.init(time: iso.string(from: t), epoch: t.timeIntervalSince1970,
                               precip_mmh: (r * 100).rounded() / 100, rain_mmh: (r * 100).rounded() / 100,
                               snow_cmh: (s * 100).rounded() / 100))
        }
        return RelayNowcast(generated: Date().timeIntervalSince1970, source: "rainviewer-motion",
                            step_minutes: stepMinutes, slots: slots)
    }

    // MARK: Fetching

    struct Index: Decodable {
        struct Radar: Decodable { let past: [Frame] }
        struct Frame: Decodable { let time: Double; let path: String }
        let host: String
        let radar: Radar
    }

    /// The two frames to line up: the newest, and the one closest to 20 minutes before it.
    static func framePair(_ frames: [Index.Frame]) -> (old: Index.Frame, new: Index.Frame)? {
        guard let new = frames.max(by: { $0.time < $1.time }) else { return nil }
        let older = frames.filter { $0.time <= new.time - 600 && $0.time >= new.time - 1800 }
        guard let old = older.min(by: { abs($0.time - (new.time - 1200)) < abs($1.time - (new.time - 1200)) }) else { return nil }
        return (old, new)
    }

    /// The radar-motion nowcast at `c`, or nil when RainViewer can't be reached, its newest frame
    /// is over 25 minutes old, or there's no radar echo anywhere in the 2x2 tiles (likely no radar
    /// coverage there, so "dry" would mean nothing).
    public static func nowcast(near c: Coordinate, now: Date = Date()) async -> RelayNowcast? {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              let pair = framePair(index.radar.past),
              now.timeIntervalSince1970 - pair.new.time < 1500 else { return nil }
        let t = tiles(for: c)
        async let oldGrid = mosaic(host: index.host, path: pair.old.path, tx: t.tx, ty: t.ty)
        async let newGrid = mosaic(host: index.host, path: pair.new.path, tx: t.tx, ty: t.ty)
        guard let old = await oldGrid, let new = await newGrid,
              new.dbz.contains(where: { $0 != nil }) else { return nil }
        return nowcast(old: old, new: new, time: Date(timeIntervalSince1970: pair.new.time),
                       minutes: (pair.new.time - pair.old.time) / 60, x: t.x, y: t.y, km: pixelKm(c))
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    static func mosaic(host: String, path: String, tx: Int, ty: Int) async -> Grid? {
        let n = 1 << zoom
        var dbz = [Double?](repeating: nil, count: 4 * tile * tile)
        for j in 0..<2 {
            for i in 0..<2 {
                let x = ((tx + i) % n + n) % n, y = ty + j
                guard y >= 0, y < n else { continue }
                guard let url = URL(string: "\(host)\(path)/\(tile)/\(zoom)/\(x)/\(y)/2/0_0.png"),
                      let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let px = rgba(data), px.count == tile * tile * 4 else { return nil }
                for yy in 0..<tile {
                    for xx in 0..<tile {
                        let k = (yy * tile + xx) * 4
                        dbz[(j * tile + yy) * (2 * tile) + i * tile + xx] = Self.dbz(r: px[k], g: px[k + 1], b: px[k + 2], a: px[k + 3])
                    }
                }
            }
        }
        return Grid(width: 2 * tile, height: 2 * tile, dbz: dbz)
    }

    /// A PNG's pixels as straight (not premultiplied) RGBA bytes.
    static func rgba(_ data: Data) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == tile, img.height == tile else { return nil }
        var px = [UInt8](repeating: 0, count: tile * tile * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: tile, height: tile, bitsPerComponent: 8,
                                      bytesPerRow: tile * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: tile, height: tile))
            return true
        }
        guard ok else { return nil }
        for k in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[k + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { px[k + c] = UInt8(min(255, Int(px[k + c]) * 255 / a)) }
        }
        return px
    }
    #endif
}
