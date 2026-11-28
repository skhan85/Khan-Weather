package com.khanweather.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.ln1p
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.tan

/**
 * Radar-motion nowcast for the next 90 minutes from RainViewer frames, where Environment Canada's
 * extrapolation (relay /v1/nowcast) is missing or dry. Port of RadarMotion.swift; the reference and
 * its check are tools/radar_motion.py. Decoding the PNG tiles is the app's job (Android Bitmap):
 * this takes their pixels as ARGB ints, straight (not premultiplied) alpha.
 */
object RadarMotion {
    const val ZOOM = 6
    const val TILE = 256
    const val WINDOW = 48
    const val MAX_SPEED_KMH = 110.0
    const val MIN_ECHO_PIXELS = 20
    const val MAX_LEAD_MINUTES = 90
    const val STEP_MINUTES = 5
    const val MIN_DBZ = 10.0

    /** One output slot, the same fields as the relay's nowcast. */
    data class Slot(val epoch: Epoch, val rainMmh: Double, val snowCmh: Double)

    class Grid(val width: Int, val height: Int, val dbz: DoubleArray /* NaN = no echo */) {
        val rain = DoubleArray(dbz.size) { rainRate(dbz[it]) }
        val snow = DoubleArray(dbz.size) { snowRate(dbz[it]) }
    }

    private val hex = listOf(
        "636159", "66635a", "69665c", "6c685d", "6f6b5f", "726e61", "757062", "787364",
        "7c7565", "7f7867", "827b69", "857d6a", "88806c", "8b826d", "8e856f", "928871",
        "9e9375", "aa9e79", "b6a97e", "c2b482", "cec087", "d2c48b", "d6c88f", "dacc93",
        "ded097", "88ddee", "6cd1eb", "51c5e8", "36bae5", "1baee2", "00a3e0", "009ad5",
        "0091ca", "0088bf", "007fb4", "0077aa", "0070a3", "00699c", "006295", "005b8e",
        "005588", "005180", "004e78", "004a70", "004768", "ffee00", "ffe000", "ffd200",
        "ffc500", "ffb700", "ffaa00", "ff9f00", "ff9500", "ff8b00", "ff8100", "ff4400",
        "f23600", "e62800", "d91b00", "cd0d00", "c10000", "a80000", "8f0000", "760000",
        "5d0000", "ffaaff", "ff9fff", "ff95ff", "ff8bff", "ff81ff", "ff77ff", "ff6cff",
        "ff62ff", "ff58ff", "ff4eff",
    ).map { it.toInt(16) }

    /** RainViewer Universal Blue rain colours: index i is dBZ i - 10. */
    fun dbz(argb: Int): Double {
        val a = (argb ushr 24) and 255
        if (a < 16) return Double.NaN
        val r = (argb shr 16) and 255
        val g = (argb shr 8) and 255
        val b = argb and 255
        var best = 0
        var bestD = Int.MAX_VALUE
        for ((i, v) in hex.withIndex()) {
            val dr = ((v shr 16) and 255) - r
            val dg = ((v shr 8) and 255) - g
            val db = (v and 255) - b
            val d = dr * dr + dg * dg + db * db
            if (d < bestD) { bestD = d; best = i }
        }
        return (best - 10).toDouble()
    }

    fun rainRate(dbz: Double): Double =
        if (dbz.isNaN() || dbz < MIN_DBZ) 0.0 else (10.0.pow(dbz / 10) / 200).pow(1 / 1.6)

    fun snowRate(dbz: Double): Double =
        if (dbz.isNaN() || dbz < MIN_DBZ) 0.0 else (10.0.pow(dbz / 10) / 2000).pow(0.5)

    data class Tiles(val tx: Int, val ty: Int, val x: Double, val y: Double)

    fun tiles(c: Coordinate): Tiles {
        val n = TILE * 2.0.pow(ZOOM)
        val gx = (c.longitude + 180) / 360 * n
        val s = c.latitude * PI / 180
        val gy = (1 - ln(tan(s) + 1 / cos(s)) / PI) / 2 * n
        val tx = (gx / TILE).roundToInt() - 1
        val ty = (gy / TILE).roundToInt() - 1
        return Tiles(tx, ty, gx - tx * TILE, gy - ty * TILE)
    }

    fun pixelKm(c: Coordinate): Double = 40075.016 * cos(c.latitude * PI / 180) / (TILE * 2.0.pow(ZOOM))

    /** Pixels per minute the rain moved from `old` to `new`; zero when it can't tell. */
    fun motion(old: Grid, new: Grid, cx: Double, cy: Double, minutes: Double, km: Double): Pair<Double, Double> {
        if (minutes <= 0 || km <= 0) return 0.0 to 0.0
        val reach = ceil(MAX_SPEED_KMH * minutes / 60 / km).toInt()
        val x0 = maxOf(cx.toInt() - WINDOW, reach); val x1 = minOf(cx.toInt() + WINDOW, new.width - reach - 1)
        val y0 = maxOf(cy.toInt() - WINDOW, reach); val y1 = minOf(cy.toInt() + WINDOW, new.height - reach - 1)
        if (x1 <= x0 || y1 <= y0) return 0.0 to 0.0
        val a = DoubleArray(new.rain.size) { ln1p(new.rain[it]) }
        val b = DoubleArray(old.rain.size) { ln1p(old.rain[it]) }
        var echo = 0
        for (y in y0 until y1) for (x in x0 until x1) if (a[y * new.width + x] > 0) echo++
        if (echo < MIN_ECHO_PIXELS) return 0.0 to 0.0
        var best = Double.POSITIVE_INFINITY; var bx = 0; var by = 0
        var zero: Double? = null
        for (dy in -reach..reach) for (dx in -reach..reach) {
            var sum = 0.0; var n = 0
            for (y in y0 until y1) {
                val rowA = y * new.width; val rowB = (y - dy) * old.width
                for (x in x0 until x1) {
                    val va = a[rowA + x]; val vb = b[rowB + x - dx]
                    if (va > 0 || vb > 0) { sum += abs(va - vb); n++ }
                }
            }
            if (n < MIN_ECHO_PIXELS) continue
            val c = sum / n
            if (dx == 0 && dy == 0) zero = c
            if (c < best) { best = c; bx = dx; by = dy }
        }
        if (!best.isFinite()) return 0.0 to 0.0
        val z = zero
        if (z != null && best > z * 0.98) return 0.0 to 0.0
        return bx / minutes to by / minutes
    }

    fun sample(values: DoubleArray, width: Int, height: Int, x: Double, y: Double): Double? {
        val xi = x.roundToInt(); val yi = y.roundToInt()
        if (xi < 1 || yi < 1 || xi >= width - 1 || yi >= height - 1) return null
        var s = 0.0
        for (j in -1..1) for (i in -1..1) s += values[(yi + j) * width + xi + i]
        return s / 9
    }

    fun nowcast(old: Grid, new: Grid, time: Epoch, minutes: Double, x: Double, y: Double, km: Double): List<Slot> {
        val (vx, vy) = motion(old, new, x, y, minutes, km)
        val out = mutableListOf<Slot>()
        for (lead in 0..MAX_LEAD_MINUTES step STEP_MINUTES) {
            val sx = x - vx * lead; val sy = y - vy * lead
            val r = sample(new.rain, new.width, new.height, sx, sy) ?: break
            val s = sample(new.snow, new.width, new.height, sx, sy) ?: break
            out += Slot(time + lead * 60.0, (r * 100).roundToInt() / 100.0, (s * 100).roundToInt() / 100.0)
        }
        return out
    }

    /** The newest frame and the one closest to 20 minutes before it (10-30 min). */
    fun framePair(times: List<Epoch>): Pair<Epoch, Epoch>? {
        val new = times.maxOrNull() ?: return null
        val old = times.filter { it <= new - 600 && it >= new - 1800 }.minByOrNull { abs(it - (new - 1200)) } ?: return null
        return old to new
    }

    /** Builds a 512x512 grid from the 2x2 tiles' ARGB pixels (top-left, top-right, bottom-left, bottom-right). */
    fun grid(tiles: List<IntArray>): Grid {
        val w = 2 * TILE
        val d = DoubleArray(w * w) { Double.NaN }
        for ((k, px) in tiles.withIndex()) {
            val i = k % 2; val j = k / 2
            for (yy in 0 until TILE) for (xx in 0 until TILE) {
                d[(j * TILE + yy) * w + i * TILE + xx] = dbz(px[yy * TILE + xx])
            }
        }
        return Grid(w, w, d)
    }
}
