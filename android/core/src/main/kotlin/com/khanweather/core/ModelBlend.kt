@file:Suppress("EnumEntryName")

package com.khanweather.core

import kotlin.math.abs
import kotlin.math.floor
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
    denmark("dmi_seamless", "Danish DMI (HARMONIE)"),
    norway("metno_seamless", "MET Norway"),
    japan("jma_seamless", "JMA (Japan)");

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
    data class Anchor(val temperature: Double, val time: Epoch, val isHomeStation: Boolean = false)

    /** The weight of `model` at `leadHours` from now, in `region`. */
    @Volatile private var regional: Map<String, Map<WeatherModel, Double>> = emptyMap()
    @Volatile private var diurnalBiasMap: Map<String, List<Double>> = emptyMap()
    @Volatile private var learnedMap: Map<String, LearnedCorrections> = emptyMap()

    /**
     * Registers what the relay learned at this place. A proven temperature correction takes the place
     * of the relay's diurnal bias for the spot (both are measured against the same uncorrected blend).
     */
    fun setLearned(learned: LearnedCorrections, coordinate: Coordinate) {
        learnedMap = learnedMap + (spotKey(coordinate) to learned)
    }

    fun learned(coordinate: Coordinate): LearnedCorrections? = learnedMap[spotKey(coordinate)]

    /** The learned multiplier on the chance of rain here, 1 when nothing is proven. */
    fun learnedPopFactor(coordinate: Coordinate): Double {
        val r = learned(coordinate)?.rain ?: return 1.0
        val f = r.pop_factor ?: return 1.0
        return if (r.enabled && f.isFinite()) f.coerceIn(0.5, 1.6) else 1.0
    }

    private val synopticModels = setOf(
        WeatherModel.europeAI, WeatherModel.europe, WeatherModel.germany,
        WeatherModel.canada, WeatherModel.us, WeatherModel.uk,
    )

    fun gridKey(c: Coordinate): String = "${(c.latitude * 2).rndInt()},${(c.longitude * 2).rndInt()}"

    fun spotKey(c: Coordinate): String = "${(c.latitude * 10).rndInt()},${(c.longitude * 10).rndInt()}"

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

    /** Registers a 3-hour UTC diurnal bias curve (8 bins covering 00..21Z; positive = models run warm). */
    fun setDiurnalBias(bias3h: List<Double>, coordinate: Coordinate? = null) {
        if (bias3h.size != 8 || !bias3h.all { it.isFinite() }) return
        val key = coordinate?.let(::spotKey) ?: "default"
        diurnalBiasMap = diurnalBiasMap + (key to bias3h.toList())
    }

    fun liveShare(leadHours: Double, observedTemperature: Double?, currentModelTemps: Map<WeatherModel, Double>?): Double {
        if (observedTemperature == null || currentModelTemps.isNullOrEmpty() ||
            leadHours < -1 || leadHours > liveWeightHours) return 0.0
        return max(0.0, min(1.0, 1 - max(leadHours, 0.0) / liveWeightHours))
    }

    /** Smoothly interpolated local diurnal bias (°C to subtract from model temperatures) at `epoch`. */
    fun diurnalBias(epoch: Double, leadHours: Double, coordinate: Coordinate? = null): Double {
        val map = diurnalBiasMap
        val learnedBins = coordinate?.let { learnedMap[spotKey(it)]?.temperature?.provenBins }
        val bins = learnedBins ?: coordinate?.let { map[spotKey(it)] } ?: map["default"] ?: return 0.0
        if (bins.size != 8) return 0.0
        val secOfDay = ((epoch % 86400.0) + 86400.0) % 86400.0
        val pos = (secOfDay / 3600.0 - 1.5) / 3.0
        val lo = floor(pos).toInt()
        val frac = pos - lo
        val i0 = ((lo % 8) + 8) % 8
        val i1 = (i0 + 1) % 8
        val raw = bins[i0] * (1 - frac) + bins[i1] * frac
        val leadScale = if (leadHours <= 120) 1.0 else max(0.6, 1.0 - 0.4 * (leadHours - 120) / 96.0)
        return raw * leadScale
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
        if (regMap != null) {
            val regTotal = regMap.entries.sumOf { (k, v) -> if (k in synopticModels && k in region.models) v else 0.0 }
            if (regTotal > 0.0) {
                val reg = regMap[model]
                if (reg != null && model in synopticModels && model in region.models) {
                    return 0.5 * prior + 0.5 * (reg / regTotal)
                }
                return 0.5 * prior
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

        val liveShare = liveShare(leadHours, observedTemperature, currentModelTemps)

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

    fun precipitationWeight(model: WeatherModel): Double = when (model) {
        WeatherModel.canadaHighRes, WeatherModel.usBlend, WeatherModel.europeHighRes -> 0.18
        WeatherModel.usHighRes -> 0.16
        WeatherModel.europe, WeatherModel.japan -> 0.14
        WeatherModel.germany, WeatherModel.france, WeatherModel.netherlands, WeatherModel.denmark, WeatherModel.norway -> 0.12
        WeatherModel.canada -> 0.10
        WeatherModel.us, WeatherModel.uk, WeatherModel.bestMatch -> 0.08
        WeatherModel.europeAI -> 0.04
        WeatherModel.blend -> 0.0
    }

    fun blendedPrecipitation(values: Map<WeatherModel, Double>, leadHours: Double,
                             region: BlendRegion = BlendRegion.home, coordinate: Coordinate? = null): Double? {
        val present = values.filterKeys { it in region.models }
        if (present.size < 3) return null
        var sum = 0.0
        var total = 0.0
        for ((model, value) in present) {
            val w = precipitationWeight(model)
            sum += max(0.0, value) * w
            total += w
        }
        if (total > 0) return sum / total
        return present.values.sumOf { max(0.0, it) } / present.size
    }

    // Daily high and low: the real high and low fall between hours.
    const val highAllowance = 0.4
    const val lowAllowance = 0.5
    const val googleWeight = 0.15
    const val googleHorizonHours = 48.0
    const val mosmixWeight = 0.12
    const val mosmixHorizonHours = 72.0

    /** A model hour counts as wet for its rain-or-snow call from this much (mm). */
    const val typeWetMm = 0.05

    /** Weighted snow share among wet models (0..1), or null when no model is wet. */
    fun precipitationSnowShare(temperature: Double, precipitation: Map<WeatherModel, Double>,
                               snowfall: Map<WeatherModel, Double>): Double? {
        if (temperature >= 3) return 0.0
        if (temperature <= -2) return 1.0
        var wetWeight = 0.0
        var snowWeight = 0.0
        for ((m, p) in precipitation) {
            if (p < typeWetMm) continue
            val s = snowfall[m] ?: continue
            val w = max(0.01, precipitationWeight(m))
            wetWeight += w
            if (s / 0.7 >= 0.5 * p) snowWeight += w
        }
        if (wetWeight <= 0.0) return null
        return snowWeight / wetWeight
    }

    /** Rain or snow this hour, from the blend's models (preserving mixed transitions). */
    fun precipitationType(temperature: Double, precipitation: Map<WeatherModel, Double>,
                          snowfall: Map<WeatherModel, Double>): PrecipitationKind {
        if (temperature >= 3) return PrecipitationKind.rain
        if (temperature <= -2) return PrecipitationKind.snow
        val share = precipitationSnowShare(temperature, precipitation, snowfall)
        if (share != null) {
            return when {
                share >= 0.7 -> PrecipitationKind.snow
                share <= 0.3 -> PrecipitationKind.rain
                else -> PrecipitationKind.mixed
            }
        }
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
