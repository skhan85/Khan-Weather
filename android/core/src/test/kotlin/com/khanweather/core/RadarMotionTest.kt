package com.khanweather.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RadarMotionTest {
    @Test
    fun coloursReadAsTheirDbz() {
        assertEquals(20.0, RadarMotion.dbz(0xff00a3e0.toInt()))
        assertEquals(50.0, RadarMotion.dbz(0xffc10000.toInt()))
        assertTrue(RadarMotion.dbz(0).isNaN())
        assertTrue(abs(RadarMotion.rainRate(20.0) - 0.65) < 0.01)
    }

    /** Same case as the iPhone test: a shower 30 km west moving east at 45 km/h. */
    @Test
    fun showerUpstreamArrivesOnTime() {
        val w = 512
        val km = 1.5
        fun frame(shiftKm: Double): RadarMotion.Grid {
            val d = DoubleArray(w * w) { Double.NaN }
            val cx = 256 - 30 / km + shiftKm / km
            val cy = 256.0
            for (y in 0 until w) for (x in 0 until w) {
                val dx = x - cx; val dy = y - cy
                if (dx * dx + dy * dy < 64) d[y * w + x] = 35.0
                if ((dx - 12) * (dx - 12) + (dy + 9) * (dy + 9) < 20) d[y * w + x] = 25.0
            }
            return RadarMotion.Grid(w, w, d)
        }
        val old = frame(-15.0)
        val new = frame(0.0)
        val (vx, vy) = RadarMotion.motion(old, new, 256.0, 256.0, 20.0, km)
        assertTrue(abs(vx * 20 * km - 15) < 1.6, "vx $vx")
        assertTrue(abs(vy) < 0.05)
        val slots = RadarMotion.nowcast(old, new, 0.0, 20.0, 256.0, 256.0, km)
        assertEquals(0.0, slots.first().rainMmh)
        val firstWet = slots.first { it.rainMmh > 1 }.epoch / 60
        assertTrue(abs(firstWet - 30) <= 6, "first wet $firstWet")
        assertTrue(slots.any { it.epoch == 2400.0 && it.rainMmh > 3 })
    }

    @Test
    fun framePairPicksTwentyMinutesBack() {
        val times = (0..12).map { it * 600.0 }
        assertEquals(6000.0 to 7200.0, RadarMotion.framePair(times))
    }
}
