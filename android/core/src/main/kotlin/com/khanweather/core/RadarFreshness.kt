package com.khanweather.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * How old the newest radar scan is (same rules as iOS's RadarFreshness): "Latest radar scan 6 min
 * ago", or a warning when the radar is running late, and Environment Canada's real newest frame
 * so the loop ends at a frame that exists.
 */
object RadarFreshness {
    enum class Level { FRESH, LATE, STALE }

    fun level(latestMs: Long, nowMs: Long = System.currentTimeMillis()): Level {
        val minutes = (nowMs - latestMs) / 60_000.0
        return when {
            minutes <= 15 -> Level.FRESH
            minutes <= 30 -> Level.LATE
            else -> Level.STALE
        }
    }

    fun age(latestMs: Long, nowMs: Long = System.currentTimeMillis()): String {
        val minutes = maxOf(0, ((nowMs - latestMs) / 60_000.0).roundToInt())
        if (minutes < 1) return "just now"
        if (minutes < 60) return "$minutes min ago"
        val h = minutes / 60
        val m = minutes % 60
        return if (m == 0) "$h hr ago" else "$h hr $m min ago"
    }

    fun text(latestMs: Long, nowMs: Long = System.currentTimeMillis()): String {
        val ago = age(latestMs, nowMs)
        return when (level(latestMs, nowMs)) {
            Level.FRESH -> "Latest radar scan $ago."
            Level.LATE -> "Radar is running late: latest scan $ago."
            Level.STALE -> "Radar is behind: latest scan $ago, so rain may have moved since."
        }
    }

    fun relative(timeMs: Long, nowMs: Long = System.currentTimeMillis()): String {
        val minutes = ((timeMs - nowMs) / 60_000.0).roundToInt()
        if (abs(minutes) <= 2) return "Now"
        return if (minutes < 0) "${-minutes} min ago" else "in $minutes min"
    }

    const val CAPABILITIES_URL =
        "https://geo.weather.gc.ca/geomet?service=WMS&version=1.3.0&request=GetCapabilities&layer=RADAR_1KM_RRAI"

    /** Environment Canada's newest radar frame (epoch ms), or null if GeoMet doesn't answer. */
    suspend fun latestEcccFrame(loader: HttpLoader = defaultLoader): Long? = try {
        parseLatest(loader.get(CAPABILITIES_URL, null, 6_000).decodeToString())
    } catch (e: Exception) {
        null
    }

    /** RainViewer's newest past radar frame (epoch ms), for places outside Environment Canada's radar. */
    suspend fun latestRainViewerFrame(loader: HttpLoader = defaultLoader): Long? = try {
        parseRainViewerLatest(loader.get("https://api.rainviewer.com/public/weather-maps.json", null, 6_000).decodeToString())
    } catch (e: Exception) {
        null
    }

    fun parseRainViewerLatest(json: String): Long? {
        val root = Json.parseToJsonElement(json).jsonObject
        val past = root["radar"]?.jsonObject?.get("past")?.jsonArray ?: return null
        return past.mapNotNull { it.jsonObject["time"]?.jsonPrimitive?.longOrNull }.maxOrNull()?.let { it * 1000 }
    }

    fun parseLatest(xml: String): Long? {
        val open = xml.indexOf("<Dimension name=\"time\"")
        if (open < 0) return null
        val tagEnd = xml.indexOf('>', open)
        if (tagEnd < 0) return null
        val tag = xml.substring(open, tagEnd)
        val body = xml.substring(tagEnd + 1).substringBefore('<')
        fun parse(s: String): Long? = try { Instant.parse(s.trim()).toEpochMilli() } catch (e: Exception) { null }
        val candidates = body.split(',').mapNotNull { item ->
            val parts = item.split('/')
            if (parts.size >= 2) parse(parts[1]) else parse(parts[0])
        }
        candidates.maxOrNull()?.let { return it }
        val d = tag.indexOf("default=\"")
        if (d >= 0) return parse(tag.substring(d + 9).substringBefore('"'))
        return null
    }

    /** The last hour (or `hours`) of frame times ending at `latestMs`, else at the usual 9-minute guess. */
    fun ecccFrameTimes(latestMs: Long?, hours: Int = 1, nowMs: Long = System.currentTimeMillis()): List<Long> {
        val six = 360_000L
        val guess = floor((nowMs - 540_000L).toDouble() / six).toLong() * six
        val end = if (latestMs != null && latestMs <= nowMs + 60_000 && nowMs - latestMs < 3 * 3_600_000L) latestMs else guess
        val step = if (hours > 1) 2 * six else six
        val oldestAllowed = nowMs - 3 * 3_600_000L + six
        val count = if (hours > 1) ((hours * 3_600_000L - six) / step).toInt() + 1 else 10
        return (count - 1 downTo 0).map { end - it * step }.filter { it >= oldestAllowed }
    }
}
