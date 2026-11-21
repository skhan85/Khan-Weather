package com.khanweather.core

import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * One "feels like" rule for every screen: Environment Canada's. Wind chill at 10° or colder in a
 * breeze, humidex at 20° or warmer when it's muggy enough to add a degree, otherwise the air
 * temperature.
 */
object FeelsLike {
    fun value(temperature: Double, windKmh: Double?, dewPoint: Double?): Pair<Double, FeelsLikeKind>? {
        if (windKmh == null && dewPoint == null) return null
        windChill(temperature, windKmh)?.let { return it to FeelsLikeKind.windChill }
        humidex(temperature, dewPoint)?.let { return it to FeelsLikeKind.humidex }
        return temperature to FeelsLikeKind.apparent
    }

    /** Magnus dew point (°C) from temperature (°C) and relative humidity (%). */
    fun dewPoint(temperature: Double, humidity: Double?): Double? {
        val rh = humidity ?: return null
        val a = 17.625
        val b = 243.04
        val gamma = ln(min(100.0, max(1.0, rh)) / 100) + (a * temperature) / (b + temperature)
        return min(temperature, (b * gamma) / (a - gamma))
    }

    /** Relative humidity (%) from temperature and dew point, Magnus formula. */
    fun relativeHumidity(temperature: Double, dewPoint: Double): Double {
        val a = 17.625
        val b = 243.04
        return min(100.0, max(0.0, 100 * exp(a * dewPoint / (b + dewPoint) - a * temperature / (b + temperature))))
    }

    /** Environment Canada's wind chill index, at or below 10 °C with wind of at least 5 km/h. */
    fun windChill(temperature: Double, windKmh: Double?): Double? {
        val v = windKmh ?: return null
        if (temperature > 10 || v < 5) return null
        val p = v.pow(0.16)
        val chill = 13.12 + 0.6215 * temperature - 11.37 * p + 0.3965 * temperature * p
        return min(chill, temperature)
    }

    /** Environment Canada's humidex from dew point, only when it adds at least a degree. */
    fun humidex(temperature: Double, dewpoint: Double?): Double? {
        val td = dewpoint ?: return null
        if (temperature < 20) return null
        val e = 6.11 * exp(5417.7530 * (1 / 273.16 - 1 / (273.15 + td)))
        val h = temperature + 0.5555 * (e - 10)
        return if (h - temperature >= 1) h else null
    }
}

/** Recomputes "feels like" for now, each hour and each fully covered day with `FeelsLike`. */
fun Forecast.withStandardFeelsLike(): Forecast {
    val copy = deepCopy()
    FeelsLike.value(current.temperature, current.windSpeed, FeelsLike.dewPoint(current.temperature, current.humidity))?.let {
        copy.current.feelsLike = it.first
        copy.current.feelsLikeKind = it.second
    }
    copy.hourly = hourly.map { hour ->
        val h = hour.copy()
        val dew = h.dewPoint ?: FeelsLike.dewPoint(h.temperature, h.humidity)
        FeelsLike.value(h.temperature, h.windSpeed, dew)?.let { h.feelsLike = it.first }
        h
    }
    copy.daily = daily.map { day ->
        val d = day.copy()
        val hours = copy.hoursOn(day)
        val feels = hours.mapNotNull { it.feelsLike }
        if (hours.size >= 18 && feels.size == hours.size) {
            d.feelsLikeHigh = feels.max()
            d.feelsLikeLow = feels.min()
        }
        d
    }
    return copy
}
