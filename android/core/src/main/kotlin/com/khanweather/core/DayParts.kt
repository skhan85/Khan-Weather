package com.khanweather.core

/** Morning, afternoon, evening and overnight, for the "today in four parts" row. */
data class DayPart(
    val kind: Kind,
    val start: Epoch,
    val temperature: Double,
    val feelsLike: Double?,
    val precipitationProbability: Double?,
    val precipitationKind: PrecipitationKind,
    val condition: WeatherCondition,
    val isDay: Boolean,
) {
    enum class Kind(val label: String) {
        Overnight("Overnight"), Morning("Morning"), Afternoon("Afternoon"), Evening("Evening");

        val showsHigh: Boolean get() = this == Morning || this == Afternoon
    }
}

/** The part of the day we're in and the three after it, from the same hours as the hourly curve. */
fun Forecast.dayParts(date: Epoch = nowEpoch(), count: Int = 4): List<DayPart> {
    val calendar = cal
    val hours = hoursStartingNow(date, 6 * (count + 1))
    if (hours.isEmpty()) return emptyList()
    val startOfDay = calendar.startOfDay(date)
    val partIndex = calendar.hour(date) / 6
    val out = mutableListOf<DayPart>()
    for (n in 0 until count) {
        val index = partIndex + n
        val kind = DayPart.Kind.entries[index % 4]
        val start = startOfDay + index * 6 * 3600.0
        val end = start + 6 * 3600
        val inPart = hours.filter { it.time + 3600 > start && it.time < end }
        if (inPart.isEmpty()) continue
        val pick = if (kind.showsHigh) inPart.maxBy { it.temperature } else inPart.minBy { it.temperature }
        val wettest = inPart.maxBy { it.precipitationProbability ?: 0.0 }
        val chance = inPart.mapNotNull { it.precipitationProbability }.maxOrNull()
        out.add(DayPart(kind, start, pick.temperature, pick.feelsLike, chance, wettest.precipitationKind,
            partCondition(inPart), inPart.count { it.isDay } * 2 >= inPart.size))
    }
    return out
}

/** Rain or snow when it's likely in the part (or falls in at least two hours); otherwise the most common sky. */
fun partCondition(hours: List<HourlyForecast>): WeatherCondition {
    val wet = hours.filter { it.condition.isWetOrStorm }
    val maxChance = hours.mapNotNull { it.precipitationProbability }.maxOrNull()
    val likely = hours.any { (it.precipitationProbability ?: 0.0) >= Forecast.headlineChance && it.condition.isPrecipitation }
    if ((maxChance ?: 100.0) >= 30.0 && wet.isNotEmpty() && (likely || wet.size >= 2)) return Forecast.mostCommon(wet.map { it.condition })!!
    return Forecast.mostCommon(hours.filter { !it.condition.isWetOrStorm }.map { it.condition })
        ?: if ((maxChance ?: 100.0) < 30.0) WeatherCondition.overcast else hours[0].condition
}
