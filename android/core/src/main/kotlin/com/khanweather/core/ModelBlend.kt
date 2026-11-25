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
    europeAI("ecmwf_aifs025_single", "European AI (AIFS)"),
    // Regional and newer models, asked for only where they cover the spot (BlendRegion.models).
    usBlend("ncep_nbm_conus", "NOAA National Blend (NBM)"),
    europeHighRes("ecmwf_ifs", "European 9 km (ECMWF IFS)"),
    france("meteofrance_seamless", "Météo-France (ARPEGE/AROME)"),
    netherlands("knmi_seamless", "Dutch KNMI (HARMONIE)"),
    denmark("dmi_seamless", "Danish DMI (HARMONIE)");

    companion object {
        fun usedForTemperatures(c: Coordinate): WeatherModel =
            if (OpenMeteoProvider.usesBlend(c)) blend else bestMatch

        /** The models asked of Open-Meteo for the comparison everywhere. */
        val requested: List<WeatherModel> = listOf(bestMatch, canada, canadaHighRes, us, usHighRes, europe, uk, germany, europeAI)

        /** The comparison's models at a spot: the usual ones plus the regional models the blend uses there. */
        fun requested(at: Coordinate): List<WeatherModel> = requested + BlendRegion.at(at).models.filter { it !in requested }
    }
}

/**
 * Khan Weather's own temperature forecast: a weighted average of several models. The weights
 * depend on where you are (BlendRegion): each part of the world has its own set, fitted on hourly
 * readings at its airports (tools/score_regions.py), with a worldwide set for everywhere else.
 * Each row is one forecast day; hours in between are interpolated. A model with no value for an
 * hour is skipped and the others share its weight. Keep in step with the iOS ModelBlend.swift.
 */
object ModelBlend {
    /** How many hours ahead a live station reading re-weights the models. */
    const val liveWeightHours = 6.0
    const val errorSoftening = 2.0

    /** A local station reading that re-weights the first hours of the blend. */
    data class Anchor(val temperature: Double, val time: Epoch)

    /** The weight of `model` at `leadHours` from now, in `region`. */
    @Volatile private var regional: Map<String, Map<WeatherModel, Double>> = emptyMap()

    private val synopticModels = setOf(
        WeatherModel.europeAI, WeatherModel.europe, WeatherModel.germany,
        WeatherModel.canada, WeatherModel.us, WeatherModel.uk,
    )

    fun gridKey(c: Coordinate): String = "${(c.latitude * 2).rndInt()},${(c.longitude * 2).rndInt()}"

    fun setRegionalWeights(raw: Map<String, Double>, coordinate: Coordinate? = null) {
        val map = mapOf(
            "europeAI" to WeatherModel.europeAI, "europe" to WeatherModel.europe,
            "germany" to WeatherModel.germany, "canada" to WeatherModel.canada,
            "us" to WeatherModel.us, "uk" to WeatherModel.uk,
            "canadaHighRes" to WeatherModel.canadaHighRes, "usHighRes" to WeatherModel.usHighRes,
        )
        val parsed = buildMap {
            for ((k, v) in raw) if (v > 0.0) map[k]?.let { put(it, v) }
        }
        if (parsed.isNotEmpty()) {
            val key = coordinate?.let(::gridKey) ?: "default"
            regional = regional + (key to parsed)
        }
    }

    private fun interpolatedPrior(model: WeatherModel, leadHours: Double, byDay: List<Map<WeatherModel, Double>>): Double {
        val x = min(max((leadHours - 12) / 24, 0.0), (byDay.size - 1).toDouble())
        val i = x.toInt()
        val j = min(i + 1, byDay.size - 1)
        val f = x - i
        return (byDay[i][model] ?: 0.0) * (1 - f) + (byDay[j][model] ?: 0.0) * f
    }

    fun weight(model: WeatherModel, leadHours: Double, region: BlendRegion = BlendRegion.home,
               coordinate: Coordinate? = null): Double {
        val byDay = region.byDay
        if (byDay.isEmpty()) return 1.0
        val prior = interpolatedPrior(model, leadHours, byDay)
        val regMap = coordinate?.let { regional[gridKey(it)] } ?: regional["default"]
        val reg = regMap?.get(model)
        if (regMap != null && reg != null && model in synopticModels) {
            val regTotal = regMap.values.sum()
            val synopticMass = regMap.keys.sumOf { interpolatedPrior(it, leadHours, byDay) }
            val regShare = if (leadHours <= 72.0) 0.5 else max(0.0, 0.5 * (1.0 - (leadHours - 72.0) / 72.0))
            if (regTotal > 0.0 && synopticMass > 0.0 && regShare > 0.0) {
                val scaledReg = (reg / regTotal) * synopticMass
                return (1.0 - regShare) * prior + regShare * scaledReg
            }
        }
        return prior
    }

    /**
     * Weighted average of the models that have a value; null if none do. For lead hours 0...6,
     * with a live station temperature and each model's temperature at that minute, the weights
     * lean toward the models that match the station.
     */
    fun blend(values: Map<WeatherModel, Double>, leadHours: Double,
              region: BlendRegion = BlendRegion.home,
              observedTemperature: Double? = null,
              currentModelTemps: Map<WeatherModel, Double>? = null,
              coordinate: Coordinate? = null): Double? {
        val present = values.filterKeys { it in region.models }
        if (present.isEmpty()) return null

        val liveShare = if (observedTemperature != null && currentModelTemps != null && currentModelTemps.isNotEmpty() &&
            leadHours >= -1 && leadHours <= liveWeightHours) {
            max(0.0, min(1.0, 1 - max(leadHours, 0.0) / liveWeightHours))
        } else 0.0

        val errorWeights = mutableMapOf<WeatherModel, Double>()
        if (liveShare > 0 && observedTemperature != null && currentModelTemps != null) {
            var invTotal = 0.0
            for (model in present.keys) {
                val priorFloor = max(weight(model, leadHours, region, coordinate), 0.04)
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
            val prior = weight(model, leadHours, region, coordinate)
            val dyn = errorWeights[model]
            val w = if (liveShare > 0 && dyn != null) prior * (1 - liveShare) + dyn * liveShare else prior
            sum += value * w
            total += w
        }
        if (total > 0) return sum / total
        return present.values.sum() / present.size
    }

    fun blendedPrecipitation(values: Map<WeatherModel, Double>, leadHours: Double,
                             region: BlendRegion = BlendRegion.home, coordinate: Coordinate? = null): Double? {
        val present = values.filterKeys { it in region.models }
        if (present.size < 3) return null
        var sum = 0.0
        var total = 0.0
        for ((model, value) in present) {
            val w = weight(model, leadHours, region, coordinate)
            sum += max(0.0, value) * w
            total += w
        }
        if (total > 0) return sum / total
        return present.values.sumOf { max(0.0, it) } / present.size
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
