package com.khanweather.core

import kotlinx.coroutines.runBlocking
import kotlin.test.*

/** 26 Nov, 9:40 pm in Milton: radar said heavy snow, then moderate rain, while nothing was falling. */
class FalseRadarEchoTest {
    private val milton = Coordinate(43.513, -79.882)
    private val now = nowEpoch()

    private fun forecast(t: Double, rh: Double?) = Forecast(milton, "America/Toronto",
        CurrentConditions(now, t, t, FeelsLikeKind.apparent, humidity = rh, condition = WeatherCondition.overcast, isDay = false),
        emptyList(), emptyList(), "t", now)

    @Test fun medianOutvotesOneBrightPixel() {
        assertEquals(0.0, ECCCRadarProvider.median(listOf(3.0, 0.0, 0.0, 0.0, 0.0)))
        assertEquals(2.5, ECCCRadarProvider.median(listOf(3.0, 2.0, 2.5, 0.0, 4.0)))
        val points = ECCCRadarProvider.neighbourhoodPoints(milton)
        assertEquals(5, points.size)
        points.drop(1).forEach { assertEquals(2.0, distanceKm(milton, it), 0.1) }
    }

    @Test fun echoOverDryAirIsIgnored() {
        val rain = RadarNow(3.0, 0.0, now)
        assertEquals(WeatherCondition.overcast, forecast(2.0, 73.0).applyingRadar(rain).current.condition)
        assertEquals(WeatherCondition.rain, forecast(2.0, 95.0).applyingRadar(rain).current.condition)
        assertEquals(WeatherCondition.snow, forecast(-8.0, 75.0).applyingRadar(RadarNow(0.0, 0.6, now)).current.condition)
    }

    private fun stations(ago: Double): String {
        val t = nowEpoch() - ago
        return """{"stations":[
          {"lat":43.52,"lon":-79.87,"city":"Milton","temperature":2.1,"observed":$t},
          {"lat":43.50,"lon":-79.89,"city":"Milton","temperature":2.3,"observed":$t},
          {"lat":43.53,"lon":-79.88,"city":"Milton","temperature":1.9,"observed":$t}]}"""
    }

    @Test fun staleRelayAnswerIsRetriedOnce() = runBlocking {
        var calls = 0
        val provider = NetatmoRelayProvider(loader = HttpLoader { _, _, _ ->
            calls += 1
            stations(if (calls == 1) 7200.0 else 300.0).toByteArray()
        })
        val o = provider.observation(milton)
        assertEquals("NETATMO", o?.dataProvider)
        assertEquals(2, calls)
    }

    @Test fun noStationsNearbyIsNotRetried() = runBlocking {
        var calls = 0
        val provider = NetatmoRelayProvider(loader = HttpLoader { _, _, _ -> calls += 1; """{"stations":[]}""".toByteArray() })
        assertNull(provider.observation(milton))
        assertEquals(1, calls)
    }
}
