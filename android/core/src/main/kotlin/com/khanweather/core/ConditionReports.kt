package com.khanweather.core

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * What someone standing outside says the sky is doing (same as ConditionReports.swift). 27 Nov,
 * 7:48 pm in Mississauga the card said "Overcast" while it drizzled: radar beams pass over drizzle
 * and stations are kilometres away, so a fresh report from the spot beats every guess.
 */
@Suppress("EnumEntryName")
enum class ReportKind {
    clear, partlyCloudy, cloudy, fog,
    drizzle, rain, heavyRain, thunderstorm,
    snow, rainAndSnow, freezingRain;

    fun label(isDay: Boolean = true): String = when (this) {
        clear -> if (isDay) "Sunny" else "Clear"
        partlyCloudy -> "Some clouds"
        cloudy -> "Cloudy"
        fog -> "Foggy"
        drizzle -> "Drizzle"
        rain -> "Raining"
        heavyRain -> "Pouring"
        thunderstorm -> "Thunder"
        snow -> "Snowing"
        rainAndSnow -> "Rain and snow"
        freezingRain -> "Freezing rain"
    }

    val condition: WeatherCondition get() = when (this) {
        clear -> WeatherCondition.clear
        partlyCloudy -> WeatherCondition.partlyCloudy
        cloudy -> WeatherCondition.overcast
        fog -> WeatherCondition.fog
        drizzle -> WeatherCondition.drizzle
        rain, heavyRain, rainAndSnow -> WeatherCondition.rain
        thunderstorm -> WeatherCondition.thunderstorm
        snow -> WeatherCondition.snow
        freezingRain -> WeatherCondition.freezingRain
    }

    val conditionText: String get() = when (this) {
        clear -> "Clear"
        partlyCloudy -> "Partly cloudy"
        cloudy -> "Cloudy"
        fog -> "Fog"
        drizzle -> "Drizzle"
        rain -> "Rain"
        heavyRain -> "Heavy rain"
        thunderstorm -> "Thunderstorm"
        snow -> "Snow"
        rainAndSnow -> "Rain and snow"
        freezingRain -> "Freezing rain"
    }

    val isWet: Boolean get() = this !in listOf(clear, partlyCloudy, cloudy, fog)

    /** The current 15-minute slot: rain mm and snow cm, in the chart's band for that word. */
    internal val slot: Pair<Double, Double> get() = when (this) {
        clear, partlyCloudy, cloudy, fog -> 0.0 to 0.0
        drizzle -> 0.1 to 0.0
        rain -> 0.4 to 0.0
        heavyRain -> 2.5 to 0.0
        thunderstorm -> 1.5 to 0.0
        snow -> 0.0 to 0.12
        rainAndSnow -> 0.15 to 0.15
        freezingRain -> 0.3 to 0.0
    }
}

@Serializable
data class ConditionReport(
    val id: String = UUID.randomUUID().toString(),
    val kind: ReportKind,
    val time: Epoch = nowEpoch(),
    val latitude: Double,
    val longitude: Double,
    /** True for a report made on this phone. */
    val mine: Boolean = true,
) {
    val coordinate: Coordinate get() = Coordinate(latitude, longitude)

    /** Holds for 45 minutes within 8 km of where it was made, whoever made it (one rule, so the
     *  widget and every phone say the same). */
    fun applies(at: Coordinate, now: Epoch = nowEpoch()): Boolean {
        val age = now - time
        return age >= -300 && age <= MAX_AGE && distanceKm(coordinate, at) <= MAX_KM
    }

    companion object {
        const val MAX_AGE = 45 * 60.0
        const val MAX_KM = 8.0
        /** This phone's reports plus the relay's, without counting this phone's twice. */
        fun merged(mine: List<ConditionReport>, relay: List<ConditionReport>) =
            mine + relay.filter { r -> mine.none { it.id == r.id } }
    }
}

/** The newest report that holds here, or null. */
fun Forecast.activeReport(reports: List<ConditionReport>, now: Epoch = nowEpoch()): ConditionReport? =
    reports.filter { it.applies(location, now) }.maxByOrNull { it.time }

/**
 * Runs last, after radar and the nowcast: a fresh report sets the sky, the card's words, the first
 * hour and the current 15-minute slot of Next 2 hours, so every screen and the widget agree.
 */
fun Forecast.applyingReports(reports: List<ConditionReport>, now: Epoch = nowEpoch()): Forecast {
    val report = activeReport(reports, now) ?: return this
    val copy = deepCopy()
    copy.current.condition = report.kind.condition
    copy.observation?.conditionText = report.kind.conditionText
    if (!report.kind.isWet || report.kind == ReportKind.thunderstorm) copy.radar = null
    val minutes = kotlin.math.max(0, kotlin.math.round((now - report.time) / 60).toInt())
    val ago = if (minutes < 1) "just now" else "$minutes min ago"
    copy.skySource = if (report.mine) "your report, $ago" else {
        val km = distanceKm(report.coordinate, location)
        val away = if (km < 1) "nearby" else "${WeatherFormat.roughDistance(km)} away"
        "someone's report $away, $ago"
    }
    val i = copy.minutely.indexOfFirst { it.time <= now && it.time + 900 > now }
    if (i >= 0) {
        val (rain, snow) = report.kind.slot
        val old = copy.minutely[i]
        val keep = report.kind.isWet && old.isWet && old.kind == PrecipitationSlot.kindOf(rain, snow)
        if (!keep) {
            copy.minutely = copy.minutely.toMutableList().also {
                it[i] = PrecipitationSlot(old.time, rain + snow * 0.7, rain, snow)
            }
        }
    }
    return copy
}
