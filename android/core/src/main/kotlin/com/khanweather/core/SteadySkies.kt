package com.khanweather.core

/** Dry skies from clearest to cloudiest; null for fog, rain, snow and storms. */
val WeatherCondition.cloudRank: Int?
    get() = when (this) {
        WeatherCondition.clear -> 0
        WeatherCondition.mainlyClear -> 1
        WeatherCondition.partlyCloudy -> 2
        WeatherCondition.mostlyCloudy -> 3
        WeatherCondition.overcast -> 4
        else -> null
    }

private val skiesByCloud = listOf(WeatherCondition.clear, WeatherCondition.mainlyClear, WeatherCondition.partlyCloudy,
    WeatherCondition.mostlyCloudy, WeatherCondition.overcast)

/**
 * One hour whose sky jumps two or more steps from both neighbours, the same way, is pulled one
 * step short of them (same as iOS's withSteadySkies): Overcast, Clear, Overcast reads Overcast,
 * Mostly cloudy, Overcast.
 */
fun Forecast.withSteadySkies(): Forecast {
    if (hourly.size < 3) return this
    val out = hourly.map { it.copy() }
    for (i in 1 until hourly.size - 1) {
        val r = hourly[i].condition.cloudRank ?: continue
        val a = hourly[i - 1].condition.cloudRank ?: continue
        val b = hourly[i + 1].condition.cloudRank ?: continue
        if (a >= r + 2 && b >= r + 2) out[i].condition = skiesByCloud[minOf(a, b) - 1]
        else if (a <= r - 2 && b <= r - 2) out[i].condition = skiesByCloud[maxOf(a, b) + 1]
    }
    return copy(hourly = out)
}
