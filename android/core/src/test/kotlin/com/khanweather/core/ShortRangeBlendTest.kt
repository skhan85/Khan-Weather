package com.khanweather.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ShortRangeBlendTest {
    private fun near(a: Double, b: Double) = assertTrue(abs(a - b) < 1e-9, "$a vs $b")

    @Test
    fun bandsJoinDayZero() {
        val r = BlendRegion.fallback.copy(shortRange = listOf(
            mapOf(WeatherModel.germany to 1.0),
            mapOf(WeatherModel.germany to 0.5, WeatherModel.europe to 0.5),
            mapOf(WeatherModel.europe to 1.0),
        ))
        assertEquals(1.0, ModelBlend.tablePrior(WeatherModel.germany, 0.0, r))
        near(0.75, ModelBlend.tablePrior(WeatherModel.germany, 2.5, r))
        near(1.0, ModelBlend.tablePrior(WeatherModel.europe, 8.5, r))
        val day0 = r.byDay[0][WeatherModel.europe] ?: 0.0
        near(day0, ModelBlend.tablePrior(WeatherModel.europe, 12.0, r))
        near((1 + day0) / 2, ModelBlend.tablePrior(WeatherModel.europe, 10.25, r))
        near(day0, ModelBlend.tablePrior(WeatherModel.europe, 3.0, r.copy(shortRange = emptyList())))
    }

    @Test
    fun tableShortRangeWeightsAreAskedFor() {
        for (r in BlendRegion.regions + BlendRegion.fallback) {
            assertTrue(r.shortRange.isEmpty() || r.shortRange.size == 3, r.id)
            for (band in r.shortRange) {
                near(1.0, (band.values.sum() * 100).let { kotlin.math.round(it) / 100 })
                for (m in band.keys) assertTrue(m in r.models, "${r.id} short-range weights $m")
            }
        }
    }
}
