@file:Suppress("EnumEntryName")

package com.khanweather.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** The weather models, with Open-Meteo's names as raw values. */
enum class WeatherModel(val raw: String, val displayName: String) {
    blend("khan_blend", "Khan Weather blend"),
    bestMatch("best_match", "Open-Meteo best match"),
    canada("gem_seamless", "Environment Canada (GEM)"),
    canadaHighRes("gem_hrdps_continental", "Environment Canada high-res (HRDPS)"),
    us("gfs_seamless", "NOAA (GFS)"),
    usHighRes("gfs_hrrr", "NOAA high-res (HRRR)"),
    europe("ecmwf_ifs025", "European (ECMWF)"),
    uk("ukmo_seamless", "UK Met Office"),
    germany("icon_seamless", "German (ICON)"),
    europeAI("ecmwf_aifs025_single", "European AI (AIFS)");

    companion object {
        fun usedForTemperatures(c: Coordinate): WeatherModel =
            if (OpenMeteoProvider.usesBlend(c)) blend else bestMatch

        val requested: List<WeatherModel> = entries.filter { it != blend }
    }
}

/**
 * Khan Weather's own temperature forecast: a weighted average of several models. The weights
 * come from 12 months of scoring at Toronto Pearson and Hamilton (see the iOS ModelBlend.swift
 * for the full story); keep the two files identical.
 */
object ModelBlend {
    val members = listOf(
        WeatherModel.canadaHighRes, WeatherModel.usHighRes, WeatherModel.canada, WeatherModel.europe,
        WeatherModel.europeAI, WeatherModel.germany, WeatherModel.uk, WeatherModel.us,
    )

    private val byDay: List<Map<WeatherModel, Double>> =
        listOf(
            mapOf(WeatherModel.germany to 0.30, WeatherModel.europe to 0.20, WeatherModel.usHighRes to 0.15, WeatherModel.canada to 0.15, WeatherModel.uk to 0.10, WeatherModel.europeAI to 0.10),
            mapOf(WeatherModel.europeAI to 0.28, WeatherModel.germany to 0.22, WeatherModel.uk to 0.185, WeatherModel.canadaHighRes to 0.12, WeatherModel.canada to 0.10, WeatherModel.europe to 0.04,
                WeatherModel.usHighRes to 0.025, WeatherModel.us to 0.025),
            mapOf(WeatherModel.europeAI to 0.35, WeatherModel.us to 0.23, WeatherModel.germany to 0.18, WeatherModel.uk to 0.125, WeatherModel.europe to 0.075, WeatherModel.canada to 0.04),
            mapOf(WeatherModel.europeAI to 0.43, WeatherModel.us to 0.235, WeatherModel.uk to 0.11, WeatherModel.germany to 0.095, WeatherModel.europe to 0.085, WeatherModel.canada to 0.045),
            mapOf(WeatherModel.europeAI to 0.47, WeatherModel.us to 0.23, WeatherModel.uk to 0.125, WeatherModel.europe to 0.075, WeatherModel.germany to 0.07, WeatherModel.canada to 0.03),
            mapOf(WeatherModel.europeAI to 0.49, WeatherModel.europe to 0.165, WeatherModel.us to 0.15, WeatherModel.uk to 0.08, WeatherModel.germany to 0.06, WeatherModel.canada to 0.055),
        )

    /** How many hours ahead a live station reading re-weights the models. */
    const val liveWeightHours = 6.0
    const val errorSoftening = 2.0

    /** A local station reading that re-weights the first hours of the blend. */
    data class Anchor(val temperature: Double, val time: Epoch)

    fun weight(model: WeatherModel, leadHours: Double): Double {
        val x = min(max((leadHours - 12) / 24, 0.0), (byDay.size - 1).toDouble())
        val i = x.toInt()
        val j = min(i + 1, byDay.size - 1)
        val f = x - i
        return (byDay[i][model] ?: 0.0) * (1 - f) + (byDay[j][model] ?: 0.0) * f
    }

    /**
     * Weighted average of the models that have a value; null if none do. For lead hours 0...6,
     * with a live station temperature and each model's temperature at that minute, the weights
     * lean toward the models that match the station.
     */
    fun blend(values: Map<WeatherModel, Double>, leadHours: Double,
              observedTemperature: Double? = null,
              currentModelTemps: Map<WeatherModel, Double>? = null): Double? {
        val present = values.filterKeys { it in members }
        if (present.isEmpty()) return null

        val liveShare = if (observedTemperature != null && currentModelTemps != null && currentModelTemps.isNotEmpty() &&
            leadHours >= -1 && leadHours <= liveWeightHours) {
            max(0.0, min(1.0, 1 - max(leadHours, 0.0) / liveWeightHours))
        } else 0.0

        val errorWeights = mutableMapOf<WeatherModel, Double>()
        if (liveShare > 0 && observedTemperature != null && currentModelTemps != null) {
            var invTotal = 0.0
            for (model in present.keys) {
                val priorFloor = max(weight(model, leadHours), 0.04)
                val nowTemp = currentModelTemps[model] ?: continue
                val err = abs(nowTemp - observedTemperature)
                val invSq = priorFloor / (err * err + errorSoftening)
                errorWeights[model] = invSq
                invTotal += invSq
            }
            if (invTotal > 0) for (m in errorWeights.keys.toList()) errorWeights[m] = errorWeights[m]!! / invTotal
        }

        var sum = 0.0
        var total = 0.0
        for ((model, value) in present) {
            val prior = weight(model, leadHours)
            val dyn = errorWeights[model]
            val w = if (liveShare > 0 && dyn != null) prior * (1 - liveShare) + dyn * liveShare else prior
            sum += value * w
            total += w
        }
        if (total > 0) return sum / total
        return present.values.sum() / present.size
    }

    // Daily high and low: the real high and low fall between hours.
    const val highAllowance = 0.4
    const val lowAllowance = 0.5

    /** A model hour counts as wet for its rain-or-snow call from this much (mm). */
    const val typeWetMm = 0.05

    /** Rain or snow this hour, from the blend's models (97% right at Pearson and Hamilton). */
    fun precipitationType(temperature: Double, precipitation: Map<WeatherModel, Double>,
                          snowfall: Map<WeatherModel, Double>): PrecipitationKind {
        if (temperature >= 3) return PrecipitationKind.rain
        if (temperature <= -2) return PrecipitationKind.snow
        var wet = 0
        var snowy = 0
        for ((m, p) in precipitation) {
            if (p < typeWetMm) continue
            val s = snowfall[m] ?: continue
            wet += 1
            if (s / 0.7 >= 0.5 * p) snowy += 1
        }
        if (wet > 0) return if (snowy * 2 >= wet) PrecipitationKind.snow else PrecipitationKind.rain
        return if (temperature <= 1) PrecipitationKind.snow else PrecipitationKind.rain
    }

    const val wetHourMm = 0.2
    const val wetDayMm = 0.5
    const val minModelsForChance = 4

    /** Open-Meteo's hourly chance averaged with the share of blend models that are wet. */
    fun hourlyChance(openMeteo: Double?, wet: Int, count: Int): Double? {
        if (count < minModelsForChance) return openMeteo
        val share = 100.0 * wet / count
        if (openMeteo == null) return share.rnd()
        return (0.5 * openMeteo + 0.5 * share).rnd()
    }

    /** Open-Meteo's chance for the day mixed with the share of models whose day total is wet. */
    fun dailyChance(openMeteo: Double?, wet: Int, count: Int, dayIndex: Int): Double? {
        if (count < minModelsForChance) return openMeteo
        val share = 100.0 * wet / count
        if (openMeteo == null) return share.rnd()
        val w = if (dayIndex <= 1) 0.75 else 0.5
        return ((1 - w) * openMeteo + w * share).rnd()
    }
}
