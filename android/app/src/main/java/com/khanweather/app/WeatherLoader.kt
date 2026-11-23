package com.khanweather.app

import android.content.Context
import com.khanweather.core.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/** Everything shown for one place, saved so the widget and a failed refresh can show it. */
@Serializable
data class Snapshot(
    val forecast: Forecast,
    val placeName: String? = null,
    val alerts: List<WeatherAlert> = emptyList(),
    val airQuality: AirQuality? = null,
    val savedAt: Epoch = nowEpoch(),
    /** False when location was off and the fallback city is shown. */
    val realLocation: Boolean = true,
)

/** The station reading last shown per spot (~1 km), to steady the next one. */
object ObservationMemory {
    private val map = mutableMapOf<String, Observation>()
    fun key(c: Coordinate) = String.format(Locale.US, "%.2f,%.2f", c.latitude, c.longitude)
    @Synchronized fun last(c: Coordinate) = map[key(c)]
    @Synchronized fun remember(c: Coordinate, o: Observation) { map[key(c)] = o }
}

object SnapshotStore {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun file(context: Context, key: String?) = File(context.cacheDir, "forecast-${key ?: "current"}.json")

    fun save(context: Context, key: String?, s: Snapshot) {
        runCatching {
            val f = file(context, key)
            val tmp = File(f.path + ".tmp")
            tmp.writeText(json.encodeToString(Snapshot.serializer(), s))
            tmp.renameTo(f)
        }
    }

    /** The last good snapshot, if younger than `maxAge` seconds. */
    fun load(context: Context, key: String?, maxAge: Double = 6 * 3600.0): Snapshot? = runCatching {
        val s = json.decodeFromString(Snapshot.serializer(), file(context, key).readText())
        if (nowEpoch() - s.forecast.fetchedAt < maxAge) s else null
    }.getOrNull()
}

/** The same fetch steps as the iPhone app, used by the app, widgets and background checks. */
object WeatherLoader {
    val forecastProvider = OpenMeteoProvider()

    fun observations(): ObservationProvider = ObservationSource.provider(Prefs.hyperlocal)

    suspend fun observation(target: Coordinate): Observation? {
        val provider = observations()
        val previous = ObservationMemory.last(target)
        return deadline(8.0) { runCatching { provider.observation(target) }.getOrNull() }?.smoothed(previous)
    }

    suspend fun radar(target: Coordinate): RadarNow? =
        deadline(6.0) { runCatching { ECCCRadarProvider().now(target) }.getOrNull() }

    suspend fun alerts(target: Coordinate): List<WeatherAlert>? =
        deadline(8.0) { runCatching { WorldAlertProvider().alerts(target) }.getOrNull() }

    suspend fun airQuality(target: Coordinate, zone: String): AirQuality? =
        runCatching { AirQualityProvider().airQuality(target, zone) }.getOrNull()

    suspend fun normals(context: Context, target: Coordinate): ClimateNormals? =
        runCatching { ClimateNormalsProvider(File(context.cacheDir, "normals")).normals(target) }.getOrNull()

    /** Model forecast, re-weighted by the station reading when it's local, then the reading and radar on top. */
    private val relayJson = Json { ignoreUnknownKeys = true }

    @Serializable
    data class RelayNowcastSlot(val epoch: Double, val rain_mmh: Double = 0.0, val snow_cmh: Double = 0.0)

    @Serializable
    data class RelayNowcast(val slots: List<RelayNowcastSlot> = emptyList())

    suspend fun radarNowcast(target: Coordinate): RelayNowcast? = deadline(6.0) {
        withContext(Dispatchers.IO) {
            runCatching {
                val u = String.format(
                    Locale.US,
                    "https://weather-relay.khanofmilton.ca/v1/nowcast?lat=%.4f&lon=%.4f&cold=0",
                    target.latitude, target.longitude,
                )
                val conn = (URL(u).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 5000; readTimeout = 5000
                }
                try {
                    if (conn.responseCode != 200) return@runCatching null
                    relayJson.decodeFromString(RelayNowcast.serializer(), conn.inputStream.bufferedReader().readText())
                } finally {
                    conn.disconnect()
                }
            }.getOrNull()
        }
    }

    private fun Forecast.applyingRadarNowcast(nc: RelayNowcast?): Forecast {
        if (nc == null || nc.slots.isEmpty() || minutely.isEmpty()) return this
        val isSnow = current.temperature <= 0.0
        val merged = minutely.map { slot ->
            val matching = nc.slots.filter { it.epoch >= slot.time && it.epoch < slot.time + 900.0 }
            if (matching.isEmpty()) return@map slot
            val peakRain = matching.maxOf { it.rain_mmh }
            val peakSnow = if (isSnow) maxOf(matching.maxOf { it.snow_cmh }, peakRain) else 0.0
            val peakRate = if (isSnow) peakSnow else peakRain
            if (peakRate < 0.20) return@map slot
            val slotAmount = maxOf(PrecipitationSlot.wetThreshold, peakRate / 4.0)
            val rain = if (isSnow) slot.rain else maxOf(slot.rain, slotAmount)
            val snow = if (isSnow) maxOf(slot.snowfall, slotAmount) else slot.snowfall
            val total = maxOf(slot.precipitation, rain + snow)
            slot.copy(precipitation = total, rain = rain, snowfall = snow)
        }
        return copy(minutely = merged)
    }

    suspend fun full(target: Coordinate, observed: Observation?, radar: RadarNow?): Forecast = coroutineScope {
        val ncTask = async { radarNowcast(target) }
        val base = forecastProvider.forecast(target) { observed?.blendAnchor }
        observed?.let { ObservationMemory.remember(target, it) }
        base.applying(observed).applyingRadar(radar).applyingRadarNowcast(ncTask.await())
    }
}
