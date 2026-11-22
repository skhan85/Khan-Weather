package com.khanweather.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import kotlin.math.abs

/** The usual daily high and low for each day of the year (1991–2020 ERA5, smoothed over two weeks). */
@Serializable
data class ClimateNormals(val location: Coordinate, val highs: List<Double>, val lows: List<Double>) {
    fun normal(date: Epoch, zoneId: String): Pair<Double, Double>? {
        if (highs.size != 365 || lows.size != 365) return null
        val (month, day) = Cal(zoneId).monthDay(date)
        val i = dayIndex(month, day)
        return highs[i] to lows[i]
    }

    /** True when these normals are for (about) the same spot as `c`, within ~10 km. */
    fun covers(c: Coordinate): Boolean =
        abs(location.latitude - c.latitude) < 0.1 && abs(location.longitude - c.longitude) < 0.13

    companion object {
        fun dayIndex(month: Int, day: Int): Int {
            val starts = intArrayOf(0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334)
            val m = month.coerceIn(1, 12)
            return starts[m - 1] + minOf(day, if (m == 2) 28 else 31) - 1
        }

        fun compute(location: Coordinate, dates: List<String>, highs: List<Double?>, lows: List<Double?>): ClimateNormals? {
            val hiSum = DoubleArray(365); val hiN = IntArray(365)
            val loSum = DoubleArray(365); val loN = IntArray(365)
            for ((k, d) in dates.withIndex()) {
                val parts = d.split("-")
                if (parts.size != 3) continue
                val m = parts[1].toIntOrNull() ?: continue
                val day = parts[2].toIntOrNull() ?: continue
                val i = dayIndex(m, day)
                highs.at(k)?.let { hiSum[i] += it; hiN[i] += 1 }
                lows.at(k)?.let { loSum[i] += it; loN[i] += 1 }
            }
            if (hiN.any { it == 0 } || loN.any { it == 0 }) return null
            fun smooth(sum: DoubleArray, n: IntArray) = (0 until 365).map { i ->
                var s = 0.0
                var c = 0
                for (j in -7..7) {
                    val k = (i + j + 365) % 365
                    s += sum[k]; c += n[k]
                }
                s / c
            }
            return ClimateNormals(location, smooth(hiSum, hiN), smooth(loSum, loN))
        }
    }
}

/** How a day compares with the normal. */
object NormalComparison {
    const val threshold = 2.0

    fun trend(high: Double, normalHigh: Double): Int {
        val d = high - normalHigh
        if (d >= threshold) return 1
        if (d <= -threshold) return -1
        return 0
    }

    fun text(high: Double, normalHigh: Double, unit: TemperatureUnit = UnitSettings.current.temperature): String {
        val normal = "normal high ${WeatherFormat.temperature(normalHigh, unit)}"
        val shown = (abs(high - normalHigh) * (if (unit == TemperatureUnit.fahrenheit) 1.8 else 1.0)).rndInt()
        return when (trend(high, normalHigh)) {
            1 -> "$shown° warmer than usual · $normal"
            -1 -> "$shown° colder than usual · $normal"
            else -> "About usual for the date · $normal"
        }
    }

    fun shortText(high: Double, normalHigh: Double, unit: TemperatureUnit = UnitSettings.current.temperature): String {
        val shown = (abs(high - normalHigh) * (if (unit == TemperatureUnit.fahrenheit) 1.8 else 1.0)).rndInt()
        return when (trend(high, normalHigh)) {
            1 -> "$shown° above normal"
            -1 -> "$shown° below normal"
            else -> "Normal for the date"
        }
    }
}

/** Fetches 1991–2020 daily highs and lows from Open-Meteo's archive once per spot and keeps them on disk. */
class ClimateNormalsProvider(private val directory: File?, private val loader: HttpLoader = defaultLoader) {
    suspend fun normals(c: Coordinate): ClimateNormals {
        val s = spot(c)
        val file = directory?.let { File(it, fmt("normals-%.2f,%.2f.json", s.latitude, s.longitude)) }
        file?.takeIf { it.exists() }?.let { f ->
            try { return Json.decodeFromString<ClimateNormals>(f.readText()) } catch (_: Exception) {}
        }
        val url = buildUrl("https://archive-api.open-meteo.com/v1/archive",
            "latitude" to fmt("%.2f", s.latitude), "longitude" to fmt("%.2f", s.longitude),
            "start_date" to "1991-01-01", "end_date" to "2020-12-31",
            "daily" to "temperature_2m_max,temperature_2m_min", "timezone" to "auto")
        val normals = parse(loader.fetch(url, timeoutSeconds = 60), s)
        try { file?.writeText(Json.encodeToString(normals)) } catch (_: Exception) {}
        return normals
    }

    companion object {
        fun spot(c: Coordinate) = Coordinate((c.latitude * 20).rnd() / 20, (c.longitude * 20).rnd() / 20)

        fun parse(data: ByteArray, location: Coordinate): ClimateNormals {
            val d = parseJson(data)["daily"]
            val dates = d["time"].arr?.mapNotNull { it.str } ?: throw ForecastException("missing daily normals")
            return ClimateNormals.compute(location, dates, d["temperature_2m_max"].doubles(), d["temperature_2m_min"].doubles())
                ?: throw ForecastException("The weather service response was missing daily normals.")
        }
    }
}
