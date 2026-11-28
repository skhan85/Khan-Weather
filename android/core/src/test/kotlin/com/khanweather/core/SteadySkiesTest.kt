package com.khanweather.core

import kotlin.test.Test
import kotlin.test.assertEquals

class SteadySkiesTest {
    private fun forecast(skies: List<WeatherCondition>): Forecast {
        val start = 1_795_870_800.0
        val hours = skies.mapIndexed { i, c -> HourlyForecast(time = start + i * 3600.0, temperature = 7.0, condition = c) }
        return Forecast(Coordinate(43.51, -79.88), "America/Toronto",
            CurrentConditions(start, 7.0, 4.0, FeelsLikeKind.apparent, condition = WeatherCondition.overcast, isDay = true),
            hours, emptyList(), "test", start)
    }

    @Test fun loneClearHourUnderCloud() {
        val o = WeatherCondition.overcast
        assertEquals(listOf(o, o, WeatherCondition.mostlyCloudy, o, o),
            forecast(listOf(o, o, WeatherCondition.clear, o, o)).withSteadySkies().hourly.map { it.condition })
    }

    @Test fun realChangesKept() {
        val skies = listOf(WeatherCondition.overcast, WeatherCondition.clear, WeatherCondition.clear, WeatherCondition.rain,
            WeatherCondition.clear, WeatherCondition.overcast, WeatherCondition.mostlyCloudy, WeatherCondition.overcast)
        assertEquals(skies, forecast(skies).withSteadySkies().hourly.map { it.condition })
    }

    @Test fun mostlyCloudyText() {
        assertEquals(WeatherCondition.mostlyCloudy, WeatherCondition.fromMetar(null, "BKN"))
        assertEquals(WeatherCondition.mostlyCloudy, WeatherCondition.fromText("Mostly Cloudy"))
    }
}
