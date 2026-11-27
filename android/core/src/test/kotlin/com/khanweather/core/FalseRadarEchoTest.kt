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

    @Test fun modelsDecideRainOrSnowNearFreezing() {
        val echo = RadarNow(3.2, 1.7, now)
        assertEquals(WeatherCondition.rain, echo.typed(0.0, PrecipitationKind.rain).condition)
        assertEquals("Moderate rain", echo.typed(0.0, PrecipitationKind.rain).description)
        assertEquals(1.7, echo.typed(0.0, PrecipitationKind.snow).snowCmPerHour)
        assertEquals(WeatherCondition.snow, echo.typed(0.0).condition)
        assertEquals(WeatherCondition.snow, echo.typed(-3.0, PrecipitationKind.rain).condition)
        assertEquals(WeatherCondition.rain, echo.typed(4.0, PrecipitationKind.snow).condition)
    }

    @Test fun chartIntensityMatchesBands() {
        // 3.2 mm/h of rain is moderate: between the Light and Heavy lines, not at the top.
        val moderate = PrecipitationSlot(now, 0.8, rain = 0.8).intensity
        assertTrue(moderate > 1.0 / 3 && moderate < 2.0 / 3)
        assertEquals(1.0, PrecipitationSlot(now, 4.0, rain = 4.0).intensity)
        assertTrue(PrecipitationSlot(now, 0.3, snowfall = 0.3).intensity >= 2.0 / 3)
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

    private fun slots(wetFrom: Int): List<PrecipitationSlot> {
        val start = kotlin.math.floor(now / 900) * 900
        return (0 until 8).map { i -> val a = if (i >= wetFrom) 0.3 else 0.0; PrecipitationSlot(start + i * 900, a, a) }
    }

    /** 27 Nov, 10:36 am in Milton: drizzling, radar dry, card "Overcast", rain "starting in about 40 min". */
    @Test fun drizzleTheRadarCantSee() {
        val f = forecast(3.0, 92.0).apply { minutely = slots(3) }
        val shown = f.agreeingNowWithNowcast(now)
        assertEquals(WeatherCondition.drizzle, shown.current.condition)
        assertEquals(Nowcast.Change.Continuing, shown.nowcast(now)?.change)
        val dry = forecast(3.0, 84.0).apply { minutely = slots(3) }
        assertEquals(WeatherCondition.overcast, dry.agreeingNowWithNowcast(now).current.condition)
        val later = forecast(3.0, 92.0).apply { minutely = slots(6) }
        assertEquals(WeatherCondition.overcast, later.agreeingNowWithNowcast(now).current.condition)
    }

    @Test fun distantDrizzleReportNeedsDampAir() {
        val o = Observation("Milton", now, 3.0, distanceKm = 3.0)
        o.noteDrizzle("Hamilton Airport", 26.0, WeatherCondition.drizzle, now, now)
        val f = forecast(3.0, 89.0).apply { observation = o; minutely = slots(99) }
        assertEquals(WeatherCondition.drizzle, f.agreeingNowWithNowcast(now).current.condition)
        val drier = forecast(3.0, 80.0).apply { observation = o; minutely = slots(99) }
        assertEquals(WeatherCondition.overcast, drier.agreeingNowWithNowcast(now).current.condition)
        val far = Observation("Milton", now, 3.0, distanceKm = 3.0)
        far.noteDrizzle("Kitchener Airport", 55.0, WeatherCondition.drizzle, now, now)
        assertNull(far.nearbyDrizzleStation)
    }

    @Test fun dryRadarKeepsDrizzleInDampAir() {
        val dryRadar = RadarNow(0.0, 0.0, now)
        val f = forecast(4.0, 93.0).apply { current.condition = WeatherCondition.drizzle }
        assertEquals(WeatherCondition.drizzle, f.applyingRadar(dryRadar).current.condition)
        val drier = forecast(4.0, 70.0).apply { current.condition = WeatherCondition.drizzle }
        assertEquals(WeatherCondition.overcast, drier.applyingRadar(dryRadar).current.condition)
    }
}
