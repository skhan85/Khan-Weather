package com.khanweather.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RadarFreshnessTest {
    private val now = 1_795_880_520_000L

    @Test fun levelsAndText() {
        assertEquals(RadarFreshness.Level.FRESH, RadarFreshness.level(now - 8 * 60_000, now))
        assertEquals(RadarFreshness.Level.LATE, RadarFreshness.level(now - 22 * 60_000, now))
        assertEquals(RadarFreshness.Level.STALE, RadarFreshness.level(now - 45 * 60_000, now))
        assertEquals("Latest radar scan 8 min ago.", RadarFreshness.text(now - 8 * 60_000, now))
        assertEquals("Radar is running late: latest scan 22 min ago.", RadarFreshness.text(now - 22 * 60_000, now))
        assertEquals("Radar is behind: latest scan 1 hr 10 min ago, so rain may have moved since.",
            RadarFreshness.text(now - 70 * 60_000, now))
        assertEquals("Now", RadarFreshness.relative(now - 60_000, now))
        assertEquals("20 min ago", RadarFreshness.relative(now - 20 * 60_000, now))
    }

    @Test fun parsesGeoMet() {
        assertNull(RadarFreshness.parseRainViewerLatest("""{"host":"h","radar":{"past":[]}}"""))
        assertEquals(1_795_880_400_000L, RadarFreshness.parseRainViewerLatest(
            """{"host":"h","radar":{"past":[{"time":1795879800,"path":"/a"},{"time":1795880400,"path":"/b"}],"nowcast":[]}}"""))
    }

    @Test fun loopEndsAtNewestFrame() {
        val late = now - 24 * 60_000
        val t = RadarFreshness.ecccFrameTimes(late, nowMs = now)
        assertEquals(10, t.size)
        assertEquals(late, t.last())
        assertEquals(now - 12 * 60_000, RadarFreshness.ecccFrameTimes(null, nowMs = now).last())
    }
}
