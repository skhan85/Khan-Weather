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

    @Serializable
    data class RelayHazards(
        val generated: Double? = null,
        val lightning: Lightning? = null,
        val hail: Hail? = null,
        val road: Road? = null,
    ) {
        @Serializable
        data class Lightning(val count: Int = 0, val distance_km: Double? = null, val bearing: String? = null)
        @Serializable
        data class Hail(val distance_km: Double? = null, val bearing: String? = null, val max_size_mm: Double? = null)
        @Serializable
        data class Road(val surface: String? = null, val ice_mm: Double? = null, val snow_mm: Double? = null)
        data class Banner(val id: String, val kind: String, val text: String)

        fun banners(): List<Banner> {
            val out = mutableListOf<Banner>()
            lightning?.takeIf { it.count > 0 }?.let { l ->
                val dist = l.distance_km?.let { "${it.rndInt()} km" } ?: "nearby"
                val dir = l.bearing?.let { " $it" } ?: ""
                val plural = if (l.count == 1) "" else "s"
                out += Banner("lightning", "lightning", "Lightning $dist$dir (${l.count} recent strike$plural).")
            }
            hail?.let { h ->
                val dist = h.distance_km?.let { "${it.rndInt()} km" } ?: "nearby"
                val dir = h.bearing?.let { " $it" } ?: ""
                val size = if ((h.max_size_mm ?: 0.0) > 0.0) " (up to ${h.max_size_mm!!.rndInt()} mm)" else ""
                out += Banner("hail", "hail", "Hail threat $dist$dir$size.")
            }
            road?.let { r ->
                val ice = r.ice_mm ?: 0.0
                val snow = r.snow_mm ?: 0.0
                val surf = (r.surface ?: "").lowercase()
                val wintry = ice >= 0.1 || snow >= 1.0 || listOf("ice", "snow", "slush", "freez").any { it in surf }
                if (wintry) {
                    val label = r.surface?.replaceFirstChar { it.uppercase() } ?: "Wintry roads"
                    val detail = when {
                        ice >= 0.1 -> String.format(Locale.US, " (%.1f mm ice)", ice)
                        snow >= 1.0 -> String.format(Locale.US, " (%.0f mm snow)", snow)
                        else -> ""
                    }
                    out += Banner("road", "road", "Roads: $label$detail.")
                }
            }
            return out
        }
    }

    @Serializable
    data class RelayConsensus(
        val generated: Double? = null,
        val sources: List<Source> = emptyList(),
        val mean_temperature: Double? = null,
    ) {
        @Serializable
        data class Source(
            val provider: String,
            val temperature: Double,
            val feels_like: Double? = null,
            val humidity: Double? = null,
            val wind_kmh: Double? = null,
            val high: Double? = null,
            val low: Double? = null,
            val condition: String? = null,
        )
    }

    suspend fun relayHazards(target: Coordinate, storms: Boolean, cold: Boolean): RelayHazards? {
        if (!storms && !cold) return null
        return deadline(6.0) {
            withContext(Dispatchers.IO) {
                runCatching {
                    val u = String.format(
                        Locale.US,
                        "https://weather-relay.khanofmilton.ca/v1/hazards?lat=%.4f&lon=%.4f&storms=%d&cold=%d",
                        target.latitude, target.longitude, if (storms) 1 else 0, if (cold) 1 else 0,
                    )
                    val conn = (URL(u).openConnection() as HttpURLConnection).apply {
                        connectTimeout = 5000; readTimeout = 5000
                    }
                    try {
                        if (conn.responseCode != 200) return@runCatching null
                        relayJson.decodeFromString(RelayHazards.serializer(), conn.inputStream.bufferedReader().readText())
                    } finally {
                        conn.disconnect()
                    }
                }.getOrNull()
            }
        }
    }

    suspend fun relayConsensus(target: Coordinate): RelayConsensus? = deadline(8.0) {
        withContext(Dispatchers.IO) {
            runCatching {
                val u = String.format(
                    Locale.US,
                    "https://weather-relay.khanofmilton.ca/v1/consensus?lat=%.4f&lon=%.4f",
                    target.latitude, target.longitude,
                )
                val conn = (URL(u).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 6000; readTimeout = 6000
                }
                try {
                    if (conn.responseCode != 200) return@runCatching null
                    relayJson.decodeFromString(RelayConsensus.serializer(), conn.inputStream.bufferedReader().readText())
                } finally {
                    conn.disconnect()
                }
            }.getOrNull()
        }
    }
}
