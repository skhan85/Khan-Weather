package com.khanweather.core

import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Port of the iOS AccuracyTests. */
class AccuracyTest {
    @Test fun scoresRankModelsByAverageMiss() {
        val log = AccuracyLog()
        log.record(AccuracyLog.Forecast("2026-11-13", mapOf("gem_seamless" to 5.0, "gfs_seamless" to 8.0), mapOf("gem_seamless" to 0.0, "gfs_seamless" to 3.0)))
        log.record(AccuracyLog.Forecast("2026-11-14", mapOf("gem_seamless" to 6.0, "gfs_seamless" to 6.0), mapOf("gem_seamless" to 1.0, "gfs_seamless" to 1.0)))
        log.record(AccuracyLog.Forecast("2026-11-14", mapOf("gem_seamless" to 99.0), emptyMap()))   // later copy ignored
        log.record(AccuracyLog.Observed("2026-11-13", 6.0, 1.0, "Georgetown"))
        assertEquals(listOf("2026-11-14"), log.unscoredDays(before = "2026-11-15"))
        val scores = log.scores()
        assertEquals(listOf(WeatherModel.canada, WeatherModel.us), scores.map { it.model })
        assertEquals(1.0, scores[0].highError)
        assertEquals(2.0, scores[1].lowError)
        assertEquals(1, scores[0].days)
    }

    @Test fun dayString() {
        val t = 1_794_736_800.0   // 2026-11-15 10:00 UTC, 5 AM in Toronto
        val toronto = ZoneId.of("America/Toronto")
        assertEquals("2026-11-15", AccuracyLog.dayString(t, toronto))
        assertEquals("2026-11-16", AccuracyLog.dayString(t, toronto, offsetDays = 1))
    }

    @Test fun parsesNearestClimateStation() {
        val json = """
        {"features": [
          {"geometry": {"coordinates": [-79.92, 43.65]},
           "properties": {"STATION_NAME": "GEORGETOWN WWTP", "LOCAL_DATE": "2026-11-13 00:00:00",
                          "MAX_TEMPERATURE": 6.5, "MIN_TEMPERATURE": 0.5}},
          {"geometry": {"coordinates": [-79.63, 43.68]},
           "properties": {"STATION_NAME": "TORONTO INTL A", "LOCAL_DATE": "2026-11-13 00:00:00",
                          "MAX_TEMPERATURE": 7.0, "MIN_TEMPERATURE": 1.0}},
          {"geometry": {"coordinates": [-79.88, 43.52]},
           "properties": {"STATION_NAME": "NO DATA", "LOCAL_DATE": "2026-11-13 00:00:00",
                          "MAX_TEMPERATURE": null, "MIN_TEMPERATURE": null}}
        ]}
        """
        val seen = assertNotNull(ClimateDailyProvider.parse(json.toByteArray(), "2026-11-13", Coordinate(43.52, -79.88)))
        assertEquals("Georgetown Wwtp", seen.station)
        assertEquals(6.5, seen.high)
    }

    @Test fun localRangeNeedsNightAndDayAndAFullDayToPost() {
        val r = AccuracyLog.LocalRange.start("2026-11-13", 3.0, "Milton", isNight = true)
        repeat(4) { r.add(5.0 + it, "Milton", isNight = false) }
        assertFalse(r.usable("2026-11-15"))      // only 5 readings
        r.add(1.0, "Milton", isNight = true)
        assertTrue(r.usable("2026-11-15"))
        assertFalse(r.usable("2026-11-14"))      // climate station still has time to post
        assertEquals(1.0, r.low); assertEquals(8.0, r.high)
    }
}
