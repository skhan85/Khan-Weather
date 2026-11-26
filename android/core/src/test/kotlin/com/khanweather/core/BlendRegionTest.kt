package com.khanweather.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Port of the iOS BlendRegionTests. */
class BlendRegionTest {
    @Test fun everyRegionsWeightsAddUpAndAreAskedFor() {
        for (r in BlendRegion.regions + BlendRegion.fallback) {
            assertEquals(6, r.byDay.size, r.id)
            for (day in r.byDay) {
                assertEquals(1.0, day.values.sum(), 0.01, r.id)
                for (m in day.keys) assertTrue(m in r.models, "${r.id} weights $m but doesn't ask for it")
            }
        }
    }

    @Test fun regionLookup() {
        assertEquals("na_east", BlendRegion.at(Coordinate(43.52, -79.88)).id)     // Milton
        assertEquals("na_west", BlendRegion.at(Coordinate(49.28, -123.12)).id)    // Vancouver
        assertEquals("europe", BlendRegion.at(Coordinate(51.5, -0.12)).id)        // London
        assertEquals("sw_asia", BlendRegion.at(Coordinate(24.86, 67.0)).id)       // Karachi
        assertEquals("east_asia", BlendRegion.at(Coordinate(35.68, 139.7)).id)    // Tokyo
        assertEquals("oceania", BlendRegion.at(Coordinate(-33.87, 151.2)).id)     // Sydney
        assertEquals("global", BlendRegion.at(Coordinate(-23.55, -46.63)).id)     // São Paulo
        assertEquals("na_east", BlendRegion.home.id)
        assertTrue(WeatherModel.uk !in BlendRegion.at(Coordinate(43.52, -79.88)).models)
        val europe = BlendRegion.at(Coordinate(51.5, -0.12))
        assertTrue(WeatherModel.us !in europe.models && WeatherModel.norway in europe.models)
        assertTrue(WeatherModel.japan in BlendRegion.at(Coordinate(35.68, 139.7)).models)
    }

    @Test fun blendUsesTheSpotsWeights() {
        val london = BlendRegion.at(Coordinate(51.5, -0.12))
        val values = london.models.withIndex().associate { (i, m) -> m to i.toDouble() }
        val w = london.byDay[2].filterKeys { it in values }
        val expected = w.entries.sumOf { values[it.key]!! * it.value } / w.values.sum()
        close(expected, ModelBlend.blend(values, 60.0, london), 1e-9)
    }

    @Test fun theBlendIsUsedWhereItBeatBestMatch() {
        assertEquals(WeatherModel.blend, WeatherModel.usedForTemperatures(Coordinate(43.52, -79.88)))
        assertEquals(WeatherModel.blend, WeatherModel.usedForTemperatures(Coordinate(51.5, -0.12)))
        assertEquals(WeatherModel.blend, WeatherModel.usedForTemperatures(Coordinate(24.86, 67.0)))
    }

    @Test fun comparisonAsksForTheRegionsOwnModels() {
        val london = WeatherModel.requested(Coordinate(51.5, -0.12))
        assertTrue(WeatherModel.france in london && WeatherModel.europeHighRes in london)
        assertTrue(WeatherModel.france !in WeatherModel.requested(Coordinate(43.52, -79.88)))
    }
}
