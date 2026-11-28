package com.khanweather.core

import java.time.format.TextStyle
import java.util.Locale

/**
 * One plain sentence over the daily list (same rules as iOS's WeekOutlook): which days bring
 * rain or snow, how warm it peaks, and any strong gusts or hard frost.
 */
object WeekOutlook {
    const val GUST_KMH = 50.0
    const val HARD_FROST_C = -5.0

    fun text(days: List<DailyForecast>, zone: String, now: Epoch = nowEpoch()): String? {
        val week = days.take(7)
        if (week.size < 3) return null
        val cal = Cal(zone)
        fun name(d: DailyForecast): String = when {
            cal.isSameDay(d.date, now) -> "today"
            cal.isSameDay(d.date, cal.addingDays(now, 1)) -> "tomorrow"
            else -> cal.localDate(d.date).dayOfWeek.getDisplayName(TextStyle.FULL, Locale.US)
        }
        fun list(names: List<String>): String = when (names.size) {
            0 -> ""
            1 -> names[0]
            else -> names.dropLast(1).joinToString(", ") + " and " + names.last()
        }
        val rain = mutableListOf<String>()
        val snow = mutableListOf<String>()
        val mixed = mutableListOf<String>()
        for (d in week) {
            // Today is left to the Now card: its headline can be this morning's drizzle, long over.
            if (!d.condition.isWetOrStorm || cal.isSameDay(d.date, now)) continue
            when (d.precipitationKind) {
                PrecipitationKind.rain -> rain += name(d)
                PrecipitationKind.snow -> snow += name(d)
                PrecipitationKind.mixed -> mixed += name(d)
            }
        }
        val wet = rain.size + snow.size + mixed.size
        val parts = mutableListOf<String>()
        when {
            wet == 0 -> parts += "Dry for the next ${week.size - 1} days"
            wet > 3 -> {
                val noun = if (snow.isEmpty() && mixed.isEmpty()) "Rain" else if (rain.isEmpty() && mixed.isEmpty()) "Snow" else "Rain or snow"
                parts += "$noun on $wet of the next ${week.size - 1} days"
            }
            else -> {
                if (rain.isNotEmpty()) parts += "Rain ${list(rain)}"
                if (snow.isNotEmpty()) parts += "snow ${list(snow)}"
                if (mixed.isNotEmpty()) parts += "rain or snow ${list(mixed)}"
            }
        }
        var first = parts.joinToString(", ").replaceFirstChar { it.uppercase() }
        week.maxByOrNull { it.high }?.let { first += ", highs peaking at ${WeatherFormat.temperature(it.high)} ${name(it)}" }
        val sentences = mutableListOf("$first.")
        week.filter { (it.windGustsMax ?: 0.0) >= GUST_KMH }.maxByOrNull { it.windGustsMax ?: 0.0 }?.let {
            sentences += "Gusts up to ${WeatherFormat.wind(it.windGustsMax)} ${name(it)}."
        }
        week.minByOrNull { it.low }?.takeIf { it.low <= HARD_FROST_C }?.let {
            val night = if (name(it) == "today") "tonight" else "${name(it)} night"
            sentences += "Hard frost $night, down to ${WeatherFormat.temperature(it.low)}."
        }
        return sentences.joinToString(" ")
    }
}
