package com.khanweather.core

import kotlin.math.abs
import kotlin.math.cos

/** How much warmer (+) or colder (-) this hour is than the same time yesterday, from the unblended model. */
fun Forecast.changeSinceYesterday(date: Epoch = nowEpoch()): Double? {
    val recent = recentHours ?: return null
    if (recent.isEmpty()) return null
    val now = recent.lastOrNull { it.time <= date && it.time + 3600 > date } ?: return null
    val then = recent.firstOrNull { abs(it.time - now.time + 86_400) < 60 } ?: return null
    return now.temperature - then.temperature
}

object YesterdayComparison {
    fun degrees(changeC: Double, unit: TemperatureUnit = UnitSettings.current.temperature): Int {
        val d = if (unit == TemperatureUnit.fahrenheit) changeC * 9 / 5 else changeC
        return d.rndInt()
    }

    fun text(changeC: Double, unit: TemperatureUnit = UnitSettings.current.temperature): String {
        val d = degrees(changeC, unit)
        if (abs(d) < 2) return "About the same as yesterday at this time"
        return "${abs(d)}° ${if (d > 0) "warmer" else "colder"} than yesterday at this time"
    }

    fun shortText(changeC: Double, unit: TemperatureUnit = UnitSettings.current.temperature): String {
        val d = degrees(changeC, unit)
        if (abs(d) < 2) return "Same as yesterday"
        return "${abs(d)}° ${if (d > 0) "warmer" else "colder"} than yesterday"
    }

    fun trend(changeC: Double, unit: TemperatureUnit = UnitSettings.current.temperature): Int {
        val d = degrees(changeC, unit)
        return if (abs(d) < 2) 0 else if (d > 0) 1 else -1
    }
}

sealed class PressureTrend {
    data class Rising(val fast: Boolean) : PressureTrend()
    data class Falling(val fast: Boolean) : PressureTrend()
    data object Steady : PressureTrend()

    /** +1, -1 or 0 for the arrow. */
    val direction: Int get() = when (this) { is Rising -> 1; is Falling -> -1; Steady -> 0 }

    val note: String
        get() = when (this) {
            is Rising -> if (fast) "Rising fast. Clearing, often windy." else "Rising. Weather usually settles."
            is Falling -> if (fast) "Falling fast. A storm may be coming." else "Falling. Clouds or rain may be on the way."
            Steady -> "Steady over the last 3 hours."
        }

    companion object {
        fun from(change: Double): PressureTrend {
            if (abs(change) < 1) return Steady
            val fast = abs(change) >= 3
            return if (change > 0) Rising(fast) else Falling(fast)
        }
    }
}

/** The model's sea-level pressure now against 3 hours ago. */
fun Forecast.pressureTrend(date: Epoch = nowEpoch()): PressureTrend? {
    val now = hour(date) ?: return null
    val p = now.pressure ?: return null
    val pool = hourly + (recentHours ?: emptyList())
    val target = now.time - 3 * 3600
    val past = pool.firstOrNull { abs(it.time - target) < 60 && it.pressure != null }?.pressure ?: return null
    return PressureTrend.from(p - past)
}

/** Rain (mm) and snow (cm) over the next `days` displayed days, starting today. */
fun Forecast.precipitationTotals(days: Int = 7, date: Epoch = nowEpoch()): Pair<Double, Double>? {
    val rows = displayDaily(date).take(days)
    if (rows.none { it.rainSum != null || it.snowfallSum != null }) return null
    return rows.mapNotNull { it.rainSum }.sum() to rows.mapNotNull { it.snowfallSum }.sum()
}

object DetailNotes {
    fun uv(hours: List<HourlyForecast>, hourText: (Epoch) -> String): String {
        val strong = hours.filter { (it.uvIndex ?: 0.0) >= 3 }
        val first = strong.firstOrNull() ?: return "Low for the rest of the day."
        val end = strong.last().time + 3600
        if (first.time == hours.firstOrNull()?.time) return "Use sun protection until ${hourText(end)}."
        return "Use sun protection from ${hourText(first.time)} to ${hourText(end)}."
    }

    fun visibility(km: Double): String = when {
        km < 1 -> "Fog. Drive slowly with low beams."
        km < 5 -> "Hazy or misty."
        km < 10 -> "A little haze."
        else -> "Clear view."
    }

    fun humidity(dewPoint: Double?): String {
        if (dewPoint == null) return ""
        val comfort = when {
            dewPoint < -5 -> "Very dry air."
            dewPoint < 10 -> "Comfortable."
            dewPoint < 16 -> "A little humid."
            dewPoint < 21 -> "Muggy."
            else -> "Oppressive."
        }
        return "Dew point ${WeatherFormat.temperature(dewPoint)} right now. $comfort"
    }

    fun gusts(gusts: Double, wind: Double?): String {
        val steady = wind?.let { "Steady wind ${WeatherFormat.wind(it)}." } ?: ""
        return when {
            gusts >= 90 -> "Damaging gusts. Stay clear of trees. $steady"
            gusts >= 60 -> "Strong gusts. Secure loose things. $steady"
            gusts >= 40 -> "Gusty. Umbrellas may flip. $steady"
            else -> steady.ifEmpty { "Light gusts." }
        }
    }
}

/** The moon's phase from the mean synodic month. */
class MoonPhase(date: Epoch = nowEpoch()) {
    /** Days since the last new moon, 0 ..< 29.53. */
    val age: Double

    init {
        val days = (date - referenceNewMoon) / 86_400
        val a = days % synodicMonth
        age = if (a < 0) a + synodicMonth else a
    }

    val illumination: Double get() = (1 - cos(2 * Math.PI * age / synodicMonth)) / 2

    /** 0 new … 4 full … 7 waning crescent. */
    val index: Int
        get() {
            val s = synodicMonth
            return when {
                age < 1 || age >= s - 1 -> 0
                age < s / 4 - 1 -> 1
                age < s / 4 + 1 -> 2
                age < s / 2 - 1 -> 3
                age < s / 2 + 1 -> 4
                age < 3 * s / 4 - 1 -> 5
                age < 3 * s / 4 + 1 -> 6
                else -> 7
            }
        }

    val name: String
        get() = listOf("New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
            "Full moon", "Waning gibbous", "Last quarter", "Waning crescent")[index]

    fun nextFullMoon(after: Epoch = nowEpoch()): Epoch {
        var days = synodicMonth / 2 - age
        if (days < 1) days += synodicMonth
        return after + days * 86_400
    }

    companion object {
        const val synodicMonth = 29.530588853
        const val referenceNewMoon = 947_182_440.0
    }
}

/** A one-line clothing tip for the rest of the day. */
object WhatToWear {
    fun tip(current: CurrentConditions, upcoming: List<HourlyForecast>, hours: Int = 12, hourText: (Epoch) -> String): String {
        val window = upcoming.take(hours)
        val feels = listOf(current.feelsLike) + window.map { it.feelsLike ?: it.temperature }
        val coldest = feels.minOrNull() ?: current.feelsLike
        val warmest = feels.maxOrNull() ?: current.feelsLike
        val extras = mutableListOf<String>()
        val wetHours = window.filter(::isWet)
        wetHours.firstOrNull()?.let { wet ->
            val hasSnow = wetHours.any { it.precipitationKind == PrecipitationKind.snow || it.precipitationKind == PrecipitationKind.mixed }
            val hasRain = wetHours.any { it.precipitationKind == PrecipitationKind.rain || it.precipitationKind == PrecipitationKind.mixed }
            val item = if (hasSnow && hasRain) "boots and an umbrella" else if (hasSnow) "boots" else "an umbrella"
            val starting = if (wet.time <= current.time + 45 * 60) "" else " from ${hourText(wet.time)}"
            extras.add(item + starting)
        }
        val gusts = maxOf(window.mapNotNull { it.windGusts }.maxOrNull() ?: 0.0, current.windGusts ?: 0.0)
        if (gusts >= 50) extras.add("something windproof")
        val uv = window.mapNotNull { it.uvIndex }.maxOrNull() ?: 0.0
        if (uv >= 6) extras.add("sunscreen")
        var line = layer(coldest, warmest)
        if (extras.size == 1) line += ", and " + extras[0]
        else if (extras.size > 1) line += ", " + extras.dropLast(1).joinToString(", ") + ", and " + extras.last()
        return "$line."
    }

    fun isWet(h: HourlyForecast): Boolean =
        (h.precipitationProbability ?: 0.0) >= 50 || (h.precipitation ?: 0.0) >= 0.3 || h.condition.isPrecipitation

    fun layer(coldest: Double, warmest: Double): String {
        val base = when {
            coldest < -15 -> "Heavy winter coat, hat and mitts"
            coldest < -5 -> "Winter coat, hat and gloves"
            coldest < 3 -> "Warm jacket"
            coldest < 10 -> "Jacket"
            coldest < 16 -> "Light jacket or sweater"
            coldest < 24 -> "T-shirt weather"
            else -> "Shorts weather"
        }
        if (warmest - coldest >= 10 && coldest < 16) return "$base you can shed later"
        return base
    }
}
