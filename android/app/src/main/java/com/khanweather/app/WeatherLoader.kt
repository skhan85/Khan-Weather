package com.khanweather.app

import android.content.Context
import com.khanweather.core.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Locale
import kotlin.math.roundToInt
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
    fun load(context: Context, key: String?, maxAge: kotlin.Double = 6 * 3600.0): Snapshot? = runCatching {
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
    data class RelayNowcastSlot(val epoch: kotlin.Double, val rain_mmh: kotlin.Double = 0.0, val snow_cmh: kotlin.Double = 0.0)

    @Serializable
    data class RelayNowcast(val slots: List<RelayNowcastSlot> = emptyList())

    suspend fun radarNowcast(target: Coordinate, cold: Boolean = false): RelayNowcast? = deadline(6.0) {
        withContext(Dispatchers.IO) {
            runCatching {
                val u = String.format(
                    Locale.US,
                    "https://weather-relay.khanofmilton.ca/v1/nowcast?lat=%.4f&lon=%.4f&cold=%d",
                    target.latitude, target.longitude, if (cold) 1 else 0,
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

    fun Forecast.applyingRadarNowcast(nc: RelayNowcast?): Forecast {
        if (nc == null || nc.slots.isEmpty() || minutely.isEmpty()) return this
        val temp = current.temperature
        val rh = current.humidity ?: 100.0
        val startEpoch = minutely[0].time
        val nearRadarClean = nc.slots.filter { it.epoch >= startEpoch - 360.0 && it.epoch < startEpoch + 2700.0 }
            .all { it.precip_mmh <= 0.0 }
        val dryVeto = (observation?.gaugesSayDry == true) && temp > 1.0 && nearRadarClean
        val merged = minutely.map { slot ->
            if (dryVeto && slot.time < startEpoch + 2700.0 && slot.snowfall == 0.0 && slot.precipitation < 0.5) {
                return@map PrecipitationSlot(slot.time, 0.0, 0.0, 0.0)
            }
            val matching = nc.slots.filter { it.epoch >= slot.time && it.epoch < slot.time + 900.0 }
            if (matching.isEmpty()) return@map slot
            val rawRain = matching.maxOf { it.rain_mmh }
            val rawSnow = matching.maxOf { it.snow_cmh }
            val rainRate: kotlin.Double
            val snowRate: kotlin.Double
            if (temp <= 1.0) {
                rainRate = 0.0
                snowRate = maxOf(rawSnow, rawRain)
            } else if (temp >= 3.0) {
                rainRate = maxOf(rawRain, rawSnow)
                snowRate = 0.0
            } else {
                rainRate = rawRain
                snowRate = rawSnow
            }
            val peakRate = maxOf(rainRate, snowRate)
            val minRate = if (snowRate <= 0.0 && rh < 80.0) 1.0 else 0.50
            if (peakRate < minRate) return@map slot
            val rain = if (rainRate >= minRate) maxOf(slot.rain, maxOf(PrecipitationSlot.wetThreshold, rainRate / 4.0)) else slot.rain
            val snow = if (snowRate >= minRate) maxOf(slot.snowfall, maxOf(PrecipitationSlot.wetThreshold, snowRate / 4.0)) else slot.snowfall
            val total = maxOf(slot.precipitation, rain + snow)
            slot.copy(precipitation = total, rain = rain, snowfall = snow)
        }
        return copy(minutely = merged)
    }


    @Serializable
    data class RelayWeights(val weights: Map<String, kotlin.Double> = emptyMap())

    @Serializable
    data class RelayGoogleHour(
        val epoch: kotlin.Double,
        val temp: kotlin.Double,
        val feels_like: kotlin.Double? = null,
        val dew_point: kotlin.Double? = null,
        val wind_kmh: kotlin.Double? = null,
        val gust_kmh: kotlin.Double? = null,
        val pop: kotlin.Double? = null,
        val precip_mm: kotlin.Double? = null,
        val snow_mm: kotlin.Double? = null,
    )

    @Serializable
    data class RelayGoogleHourly(val hours: List<RelayGoogleHour> = emptyList())

    suspend fun googleHourly(target: Coordinate): RelayGoogleHourly? = deadline(3.0) {
        withContext(Dispatchers.IO) {
            runCatching {
                val u = String.format(
                    Locale.US,
                    "https://weather-relay.khanofmilton.ca/v1/google-hourly?lat=%.4f&lon=%.4f",
                    target.latitude, target.longitude,
                )
                val conn = (URL(u).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 4000; readTimeout = 4000
                }
                try {
                    if (conn.responseCode != 200) return@runCatching null
                    relayJson.decodeFromString(RelayGoogleHourly.serializer(), conn.inputStream.bufferedReader().readText())
                } finally {
                    conn.disconnect()
                }
            }.getOrNull()
        }
    }

    fun Forecast.applyingGoogleHourly(gh: RelayGoogleHourly?): Forecast {
        if (gh == null || gh.hours.isEmpty() || hourly.isEmpty()) return this
        val byHour = gh.hours.associateBy { kotlin.math.round(it.epoch / 3600.0).toLong() * 3600L }
        val cutoff = current.time + 96 * 3600.0
        var changed = false
        val copy = deepCopy()
        copy.hourly = hourly.map { hour ->
            if (hour.time > cutoff) return@map hour
            val g = byHour[kotlin.math.round(hour.time / 3600.0).toLong() * 3600L] ?: return@map hour
            val h = hour.copy()
            h.temperature = 0.75 * h.temperature + 0.25 * g.temp
            val dp = h.dewPoint; val gdp = g.dew_point
            if (dp != null && gdp != null) h.dewPoint = minOf(h.temperature, 0.75 * dp + 0.25 * gdp)
            val w = h.windSpeed; val gw = g.wind_kmh
            if (w != null && gw != null) h.windSpeed = maxOf(0.0, 0.75 * w + 0.25 * gw)
            changed = true
            h
        }
        if (!changed) return this
        val hiAllow = if (extremesIncludePeak == true) ModelBlend.highAllowance else 0.0
        val loAllow = if (extremesIncludePeak == true) ModelBlend.lowAllowance else 0.0
        copy.daily = copy.daily.map { day ->
            val hrs = copy.hoursOn(day)
            if (hrs.size < 18) day else day.copy(
                high = hrs.maxOf { it.temperature } + hiAllow,
                low = hrs.minOf { it.temperature } - loAllow,
            )
        }
        val first = copy.hourly.firstOrNull()
        if (first != null && kotlin.math.abs(first.time - current.time) < 1800.0) {
            copy.current.temperature = first.temperature
        }
        return copy.withStandardFeelsLike()
    }

    suspend fun regionalWeights(target: Coordinate): Map<String, kotlin.Double>? = deadline(3.0) {
        withContext(Dispatchers.IO) {
            runCatching {
                val u = String.format(
                    Locale.US,
                    "https://weather-relay.khanofmilton.ca/v1/weights?lat=%.2f&lon=%.2f",
                    target.latitude, target.longitude,
                )
                val conn = (URL(u).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 4000; readTimeout = 4000
                }
                try {
                    if (conn.responseCode != 200) return@runCatching null
                    val w = relayJson.decodeFromString(RelayWeights.serializer(), conn.inputStream.bufferedReader().readText()).weights
                    if (w.isNotEmpty()) w.also { ModelBlend.setRegionalWeights(it, target) } else null
                } finally {
                    conn.disconnect()
                }
            }.getOrNull()
        }
    }

    fun Forecast.calibratingEnsemblePop(): Forecast {
        val calHours = hourly.map { h ->
            val n = h.modelCount; val w = h.modelsWet; val raw = h.precipitationProbability
            if (n != null && n == 3 && w != null && raw != null) {
                val ens = (w.toDouble() / n.toDouble()) * 100.0
                h.copy(precipitationProbability = (0.6 * raw + 0.4 * ens).roundToInt().toDouble())
            } else h
        }
        val calendar = cal
        val calDays = daily.map { d ->
            val dayHours = calHours.filter { calendar.isSameDay(it.time, d.date) }
            val ensMax = if (dayHours.size >= 6) dayHours.mapNotNull { it.precipitationProbability }.maxOrNull() else null
            var pop = if (ensMax != null && d.precipitationProbability != null) {
                (0.5 * d.precipitationProbability!! + 0.5 * ensMax).roundToInt().toDouble()
            } else d.precipitationProbability
            val totalMm = (d.rainSum ?: 0.0) + (d.snowfallSum ?: 0.0)
            if (totalMm >= 10.0 && pop != null) pop = maxOf(pop, 65.0)
            else if (totalMm >= 5.0 && d.condition.isPrecipitation && pop != null) pop = maxOf(pop, 50.0)
            else if (totalMm >= 1.0 && d.condition.isPrecipitation && pop != null) pop = maxOf(pop, 40.0)
            else if (totalMm < 0.5 && !d.condition.isPrecipitation && pop != null && pop > 25.0) pop = 25.0
            val downgraded = (pop ?: 0.0) < 30.0 && totalMm < 1.0 && d.condition.isPrecipitation
            val cond = if (downgraded) WeatherCondition.overcast else d.condition
            d.copy(precipitationProbability = pop, condition = cond, summary = if (downgraded) null else d.summary)
        }
        return copy(hourly = calHours, daily = calDays)
    }

    suspend fun full(target: Coordinate, observed: Observation?, radar: RadarNow?): Forecast = coroutineScope {
        val knownTemp = observed?.temperature ?: ObservationMemory.last(target)?.temperature
        val likelyCold = knownTemp?.let { it <= 4.0 } ?: (kotlin.math.abs(target.latitude) >= 25.0)
        val ncTask = async { radarNowcast(target, cold = likelyCold) }
        val weightsTask = async { regionalWeights(target) }
        val googleTask = async { googleHourly(target) }
        val base = forecastProvider.forecast(target, regionalWeights = { weightsTask.await() }) { observed?.blendAnchor }
        observed?.let { ObservationMemory.remember(target, it) }
        base.applyingGoogleHourly(googleTask.await()).applying(observed).applyingRadar(radar).applyingRadarNowcast(ncTask.await()).calibratingEnsemblePop()
    }

    @Serializable
    data class RelayHazards(
        val generated: kotlin.Double? = null,
        val lightning: Lightning? = null,
        val hail: Hail? = null,
        val road: Road? = null,
    ) {
        @Serializable
        data class Lightning(val count: Int = 0, val distance_km: kotlin.Double? = null, val bearing: String? = null)
        @Serializable
        data class Hail(val distance_km: kotlin.Double? = null, val bearing: String? = null, val max_size_mm: kotlin.Double? = null)
        @Serializable
        data class Road(val surface: String? = null, val ice_mm: kotlin.Double? = null, val snow_mm: kotlin.Double? = null)
        data class Banner(val id: String, val kind: String, val text: String)

        fun banners(): List<Banner> {
            val out = mutableListOf<Banner>()
            lightning?.takeIf { it.count > 0 }?.let { l ->
                val dist = l.distance_km?.let { "${it.roundToInt()} km" } ?: "nearby"
                val dir = l.bearing?.let { " $it" } ?: ""
                val plural = if (l.count == 1) "" else "s"
                out += Banner("lightning", "lightning", "Lightning $dist$dir (${l.count} recent strike$plural).")
            }
            hail?.let { h ->
                val dist = h.distance_km?.let { "${it.roundToInt()} km" } ?: "nearby"
                val dir = h.bearing?.let { " $it" } ?: ""
                val size = if ((h.max_size_mm ?: 0.0) > 0.0) " (up to ${h.max_size_mm!!.roundToInt()} mm)" else ""
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
        val generated: kotlin.Double? = null,
        val sources: List<Source> = emptyList(),
        val mean_temperature: kotlin.Double? = null,
    ) {
        @Serializable
        data class Source(
            val provider: String,
            val temperature: kotlin.Double,
            val feels_like: kotlin.Double? = null,
            val humidity: kotlin.Double? = null,
            val wind_kmh: kotlin.Double? = null,
            val high: kotlin.Double? = null,
            val low: kotlin.Double? = null,
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
