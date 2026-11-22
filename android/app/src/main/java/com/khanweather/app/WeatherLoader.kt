package com.khanweather.app

import android.content.Context
import com.khanweather.core.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Locale

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
    suspend fun full(target: Coordinate, observed: Observation?, radar: RadarNow?): Forecast {
        val base = forecastProvider.forecast(target) { observed?.blendAnchor }
        observed?.let { ObservationMemory.remember(target, it) }
        return base.applying(observed).applyingRadar(radar)
    }
}
