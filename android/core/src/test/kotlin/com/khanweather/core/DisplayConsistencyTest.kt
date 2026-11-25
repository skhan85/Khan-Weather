package com.khanweather.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DisplayConsistencyTest {
    private val midnight = torontoMidnight(2026, 11, 19)

    private fun forecast(temp: (Int) -> Double): Forecast {
        val hours = (0 until 48).map { h -> HourlyForecast(time = midnight + h * 3600.0, temperature = temp(h), condition = WeatherCondition.overcast) }
        val current = CurrentConditions(midnight, temp(0), temp(0), FeelsLikeKind.apparent, condition = WeatherCondition.overcast, isDay = false)
        val days = listOf(
            DailyForecast(date = midnight, high = 10.0, low = -3.0, condition = WeatherCondition.overcast),
            DailyForecast(date = midnight + 86400, high = 8.0, low = 1.0, condition = WeatherCondition.overcast),
        )
        return Forecast(Coordinate(43.5, -79.9), "America/Toronto", current, hours, days, "test", midnight)
    }

    @Test fun blendedHighAndLowIncludeTheBetweenHoursPeak() {
        var f = forecast { h -> if (h == 14) 9.0 else if (h == 6) 1.0 else 5.0 }
        val temps = OpenMeteoProvider.ModelTemperatures()
        for (h in f.hourly) temps.hourly[h.time.toLong()] = OpenMeteoProvider.ModelTemperatures.Hour(h.temperature, null, h.temperature, h.temperature, 6, 0, 0)
        f = f.applying(temps)
        close(9.4, f.daily[0].high, 0.001)
        close(0.5, f.daily[0].low, 0.001)
        close(4.5, f.displayDay(midnight + 15 * 3600)?.low, 0.001)
    }

    @Test fun tonightLowInTheEvening() {
        val f = forecast { h -> if (h == 5) -3.0 else if (h == 30) 2.0 else 6.0 }
        val threePM = midnight + 15 * 3600
        assertEquals(2.0, f.tonightLow(threePM))
        assertEquals(2.0, f.displayDay(threePM)?.low)
        assertEquals(1.0, f.displayDaily(threePM)[1].low)
    }

    @Test fun tonightBeforeDawnIsTheNightWeAreIn() {
        val f = forecast { h -> if (h == 5) -3.0 else if (h == 30) 2.0 else 6.0 }
        assertEquals(-3.0, f.tonightLow(midnight + 2 * 3600))
    }

    @Test fun displayLowNeverAboveHigh() {
        assertEquals(10.0, forecast { 14.0 }.displayDay(midnight + 12 * 3600)?.low)
    }

    @Test fun coldMorningLowIncludesCurrentTemperature() {
        val f = forecast { h -> if (h <= 9) -3.0 else if (h == 14) 3.0 else 1.0 }
        val nineAM = midnight + 9 * 3600
        f.current.time = nineAM
        f.current.temperature = -3.0
        assertEquals(1.0, f.tonightLow(nineAM))
        assertEquals(-3.0, f.displayDay(nineAM)?.low)
    }

    @Test fun blendAnchorOnlyForLocalStations() {
        val near = Observation(stationName = "Campbellville", observedAt = midnight, temperature = 4.0, distanceKm = 6.0)
        val far = Observation(stationName = "Toronto Pearson", observedAt = midnight, temperature = 7.0, distanceKm = 28.0)
        assertEquals(ModelBlend.Anchor(4.0, midnight), near.blendAnchor)
        assertNull(far.blendAnchor)
    }

    @Test fun mixedPrecipitationDetectedForRainAndSnow() {
        val mixedDay = DailyForecast(date = midnight, high = 3.0, low = -1.0, condition = WeatherCondition.rain, rainSum = 1.5, snowfallSum = 0.4)
        val rainDay = DailyForecast(date = midnight, high = 8.0, low = 3.0, condition = WeatherCondition.rain, rainSum = 4.0, snowfallSum = 0.0)
        val dryMixedSummary = DailyForecast(date = midnight, high = 3.0, low = -1.0, condition = WeatherCondition.overcast, rainSum = 1.5, snowfallSum = 0.4)
        assertEquals(true, mixedDay.isMixedPrecipitation)
        assertEquals(false, rainDay.isMixedPrecipitation)
        assertEquals(false, dryMixedSummary.isMixedPrecipitation)
    }
}
