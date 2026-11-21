package com.khanweather.core

import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

/**
 * Each model's next-day high and low, written down the day before, then checked against what
 * Environment Canada's nearest climate station recorded. Port of the iOS Accuracy.swift; keep
 * the two in step.
 */
@Serializable
data class AccuracyLog(
    val forecasts: MutableList<Forecast> = mutableListOf(),
    val observed: MutableList<Observed> = mutableListOf(),
) {
    @Serializable
    data class Forecast(
        val day: String,                    // "2026-11-15", local to the place
        val highs: Map<String, Double>,     // WeatherModel raw value -> °C
        val lows: Map<String, Double>,
    )

    @Serializable
    data class Observed(val day: String, val high: Double, val low: Double, val station: String)

    data class Score(val model: WeatherModel, val days: Int, val highError: Double, val lowError: Double) {
        val overall: Double get() = (highError + lowError) / 2
    }

    /**
     * The day's lowest and highest local station reading, seen while the app was open. A stand-in
     * for the climate station's record when that never arrives, so it is used only with care.
     */
    @Serializable
    data class LocalRange(
        val day: String,
        var high: Double,
        var low: Double,
        var station: String,
        var samples: Int = 1,
        var nightSamples: Int? = null,
    ) {
        fun add(temperature: Double, station: String, isNight: Boolean) {
            high = maxOf(high, temperature)
            low = minOf(low, temperature)
            this.station = station
            samples += 1
            if (isNight) nightSamples = (nightSamples ?: 0) + 1
        }

        /**
         * Only after the climate station has had a full day to post (the day before yesterday or
         * older), and only with readings overnight and through the day.
         */
        fun usable(today: String): Boolean {
            val cutoff = day(today, -1) ?: return false
            if (day >= cutoff) return false
            val night = nightSamples ?: 0
            return samples >= 6 && night >= 1 && samples - night >= 3
        }

        companion object {
            fun start(day: String, temperature: Double, station: String, isNight: Boolean) =
                LocalRange(day, temperature, temperature, station, 1, if (isNight) 1 else 0)

            /** Whether `t` falls between midnight and 8 AM where the reading was taken. */
            fun isNight(t: Epoch, zone: ZoneId): Boolean = Cal(zone).hour(t) < 8
        }
    }

    fun record(f: Forecast) {
        if (forecasts.any { it.day == f.day }) return   // keep the day-before forecast
        forecasts.add(f)
        while (forecasts.size > KEEP_DAYS) forecasts.removeAt(0)
    }

    fun record(o: Observed) {
        observed.removeAll { it.day == o.day }
        observed.add(o)
        while (observed.size > KEEP_DAYS) observed.removeAt(0)
    }

    /** Days that have a forecast but no observation yet, oldest first, excluding `today` and later. */
    fun unscoredDays(before: String): List<String> {
        val seen = observed.map { it.day }.toSet()
        return forecasts.map { it.day }.filter { it < before && it !in seen }.sorted()
    }

    /** Mean absolute error per model over the scored days, best first. */
    fun scores(): List<Score> {
        val truth = observed.associateBy { it.day }
        val out = mutableListOf<Score>()
        for (model in WeatherModel.entries) {
            val hi = mutableListOf<Double>(); val lo = mutableListOf<Double>()
            for (f in forecasts) {
                val o = truth[f.day] ?: continue
                f.highs[model.raw]?.let { hi.add(abs(it - o.high)) }
                f.lows[model.raw]?.let { lo.add(abs(it - o.low)) }
            }
            val n = minOf(hi.size, lo.size)
            if (n == 0) continue
            out.add(Score(model, n, hi.sum() / hi.size, lo.sum() / lo.size))
        }
        return out.sortedBy { it.overall }
    }

    companion object {
        const val KEEP_DAYS = 45

        /** "2026-11-15" shifted by `days`, or null if it isn't a date. */
        fun day(day: String, offsetBy: Int): String? = try {
            LocalDate.parse(day).plusDays(offsetBy.toLong()).toString()
        } catch (e: Exception) {
            null
        }

        /** `t` (plus `offsetDays`) in `zone`, as "yyyy-MM-dd". */
        fun dayString(t: Epoch, zone: ZoneId, offsetDays: Int = 0): String =
            Cal(zone).localDate(t).plusDays(offsetDays.toLong()).toString()
    }
}

/** Swift's `String.capitalized`: first letter of each word upper case, the rest lower case. */
fun String.swiftCapitalized(): String {
    val sb = StringBuilder(length)
    var startOfWord = true
    for (ch in this) {
        if (ch.isLetterOrDigit()) {
            sb.append(if (startOfWord) ch.uppercaseChar() else ch.lowercaseChar())
            startOfWord = false
        } else {
            sb.append(ch)
            startOfWord = true
        }
    }
    return sb.toString()
}

/**
 * A day's recorded high and low from Environment Canada's climate stations
 * (https://api.weather.gc.ca, collection `climate-daily`). Canada only.
 */
class ClimateDailyProvider(private val loader: HttpLoader = defaultLoader) {
    suspend fun observed(day: String, near: Coordinate): AccuracyLog.Observed? {
        if (!ECCC.mightBeInCanada(near)) return null
        val span = 0.35
        val bbox = listOf(near.longitude - span * 1.4, near.latitude - span,
            near.longitude + span * 1.4, near.latitude + span).joinToString(",") { fmt("%.3f", it) }
        val url = buildUrl("https://api.weather.gc.ca/collections/climate-daily/items",
            "f" to "json", "bbox" to bbox, "datetime" to day, "limit" to "50")
        return parse(loader.fetch(url), day, near)
    }

    companion object {
        /** The nearest station that recorded both a high and a low on `day`. */
        fun parse(data: ByteArray, day: String, near: Coordinate): AccuracyLog.Observed? {
            val features = parseJson(data)["features"].arr ?: throw ForecastException("missing features")
            var bestDistance = Double.POSITIVE_INFINITY
            var best: AccuracyLog.Observed? = null
            for (feature in features) {
                val p = feature["properties"].obj ?: continue
                val date = p["LOCAL_DATE"].str ?: continue
                if (!date.startsWith(day)) continue
                val high = p["MAX_TEMPERATURE"].numOnly ?: continue
                val low = p["MIN_TEMPERATURE"].numOnly ?: continue
                val point = ECCC.pointCoordinate(feature["geometry"]) ?: continue
                val distance = distanceKm(near, point)
                if (distance >= bestDistance) continue
                bestDistance = distance
                val name = p["STATION_NAME"].str ?: "Climate station"
                best = AccuracyLog.Observed(day, high, low, name.swiftCapitalized())
            }
            return best
        }
    }
}
