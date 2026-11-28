package com.khanweather.core

import kotlin.test.Test
import kotlin.test.assertEquals

class WeekOutlookTest {
    private val now = parseIsoDate("2026-11-28T16:00:00Z")!!

    private fun days(rows: List<Triple<Pair<Double, Double>, WeatherCondition, Double?>>): List<DailyForecast> =
        rows.mapIndexed { i, (hl, c, gust) ->
            DailyForecast(date = java.time.LocalDate.of(2026, 11, 28).plusDays(i.toLong()).atStartOfDay(torontoCal.zone).toEpochSecond().toDouble(),
                high = hl.first, low = hl.second, condition = c,
                rainSum = if (c.isPrecipitation) 5.0 else 0.0, snowfallSum = 0.0, windGustsMax = gust)
        }

    @Test fun rainDaysPeakAndGusts() {
        val week = days(listOf(
            Triple(9.0 to 3.0, WeatherCondition.overcast, 30.0), Triple(8.0 to 4.0, WeatherCondition.rain, 40.0),
            Triple(6.0 to 0.0, WeatherCondition.partlyCloudy, 51.0), Triple(5.0 to -1.0, WeatherCondition.partlyCloudy, null),
            Triple(7.0 to 3.0, WeatherCondition.overcast, null), Triple(12.0 to 2.0, WeatherCondition.overcast, null),
            Triple(7.0 to 3.0, WeatherCondition.rain, null)))
        assertEquals("Rain tomorrow and Friday, highs peaking at 12° Thursday. Gusts up to 51 km/h Monday.",
            WeekOutlook.text(week, "America/Toronto", now))
    }

    @Test fun dryWeekWithHardFrost() {
        val week = days(listOf(Triple(2.0 to -3.0, WeatherCondition.clear, null), Triple(1.0 to -8.0, WeatherCondition.clear, null),
            Triple(3.0 to -2.0, WeatherCondition.partlyCloudy, null)))
        assertEquals("Dry for the next 2 days, highs peaking at 3° Monday. Hard frost tomorrow night, down to -8°.",
            WeekOutlook.text(week, "America/Toronto", now))
    }
}
