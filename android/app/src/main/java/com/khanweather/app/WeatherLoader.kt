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
    data class RelayNowcastSlot(
        val epoch: kotlin.Double,
        val precip_mmh: kotlin.Double = 0.0,
        val rain_mmh: kotlin.Double = 0.0,
        val snow_cmh: kotlin.Double = 0.0,
    )

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

    /**
     * `radarNow` is the checked reading over the spot. When it is dry but the relay says it's coming
     * down right now, the relay is carrying an echo the check threw out (one bright pixel), so the
     * relay is ignored.
     */
    fun Forecast.applyingRadarNowcast(nc: RelayNowcast?, radarNow: RadarNow? = null): Forecast {
        if (nc == null || nc.slots.isEmpty() || minutely.isEmpty()) return this
        if (radarNow != null && !radarNow.isPrecipitating) {
            val atFrame = nc.slots.filter { kotlin.math.abs(it.epoch - radarNow.time) <= 600.0 }
            if (atFrame.any { maxOf(it.rain_mmh, it.snow_cmh, it.precip_mmh) >= 0.5 }) return this
        }
        val temp = current.temperature
        val rh = current.humidity ?: 100.0
        val startEpoch = minutely[0].time
        val nearRadarClean = nc.slots.filter { it.epoch >= startEpoch - 360.0 && it.epoch < startEpoch + 2700.0 }
            .all { it.precip_mmh <= 0.0 && it.rain_mmh <= 0.0 && it.snow_cmh <= 0.0 }
        val dryVeto = (observation?.gaugesSayDry == true) && temp > 1.0 && nearRadarClean
        val merged = minutely.map { slot ->
            if (dryVeto && slot.time < startEpoch + 2700.0 && slot.snowfall == 0.0 && slot.precipitation < 0.5) {
                return@map PrecipitationSlot(slot.time, 0.0, 0.0, 0.0)
            }
            val matching = nc.slots.filter { it.epoch >= slot.time && it.epoch < slot.time + 900.0 }
            if (matching.isEmpty()) return@map slot
            // Same rain-or-snow call as the Now card: the relay's rain and snow are one echo read both ways.
            val typed = RadarNow(matching.maxOf { it.rain_mmh }, matching.maxOf { it.snow_cmh }, slot.time)
                .typed(temp, modelPrecipitationKind(slot.time))
            val rainRate = typed.rainMmPerHour
            val snowRate = typed.snowCmPerHour
            val peakRate = maxOf(rainRate, snowRate)
            // Light echoes count in saturated air, where they're drizzle reaching the ground.
            val minRate = if (snowRate <= 0.0 && rh < 80.0) 1.0 else if (rh >= dampEchoHumidity) 0.2 else 0.50
            if (peakRate < minRate) return@map slot
            val rain = if (rainRate >= minRate) maxOf(slot.rain, maxOf(PrecipitationSlot.wetThreshold, rainRate / 4.0)) else slot.rain
            val snow = if (snowRate >= minRate) maxOf(slot.snowfall, maxOf(PrecipitationSlot.wetThreshold, snowRate / 4.0)) else slot.snowfall
            val total = maxOf(slot.precipitation, rain + snow)
            slot.copy(precipitation = total, rain = rain, snowfall = snow)
        }
        return copy(minutely = merged)
    }


    @Serializable
    data class RelayWeights(
        val weights: Map<String, kotlin.Double> = emptyMap(),
        val diurnal_bias_3h: List<kotlin.Double>? = null,
    )

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

    @Serializable
    data class RelayMosmixHour(
        val epoch: kotlin.Double,
        val temp: kotlin.Double,
        val dew_point: kotlin.Double? = null,
        val wind_kmh: kotlin.Double? = null,
        val gust_kmh: kotlin.Double? = null,
        val precip_mm: kotlin.Double? = null,
    )

    @Serializable
    data class RelayMosmixHourly(
        val distance_km: kotlin.Double? = null,
        val hours: List<RelayMosmixHour> = emptyList(),
    )

    private class SupplementHour(
        val epoch: kotlin.Double,
        val temp: kotlin.Double,
        val dewPoint: kotlin.Double?,
        val windKmh: kotlin.Double?,
    )

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

    suspend fun mosmixHourly(target: Coordinate): RelayMosmixHourly? = deadline(2.5) {
        withContext(Dispatchers.IO) {
            runCatching {
                val u = String.format(
                    Locale.US,
                    "https://weather-relay.khanofmilton.ca/v1/mosmix?lat=%.4f&lon=%.4f",
                    target.latitude, target.longitude,
                )
                val conn = (URL(u).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 4000; readTimeout = 4000
                }
                try {
                    if (conn.responseCode != 200) return@runCatching null
                    relayJson.decodeFromString(RelayMosmixHourly.serializer(), conn.inputStream.bufferedReader().readText())
                } finally {
                    conn.disconnect()
                }
            }.getOrNull()
        }
    }

    fun Forecast.applyingMosmixHourly(mx: RelayMosmixHourly?): Forecast {
        if (mx == null || mx.hours.isEmpty()) return this
        val dist = mx.distance_km ?: 0.0
        val weight = ModelBlend.mosmixWeight * maxOf(0.0, 1.0 - dist / 25.0)
        if (weight <= 0.005) return this
        val items = mx.hours.map { SupplementHour(it.epoch, it.temp, it.dew_point, it.wind_kmh) }
        return applyingHourlySupplement(items, weight, ModelBlend.mosmixHorizonHours)
    }

    fun Forecast.applyingGoogleHourly(gh: RelayGoogleHourly?): Forecast {
        if (gh == null || gh.hours.isEmpty()) return this
        val items = gh.hours.map { SupplementHour(it.epoch, it.temp, it.dew_point, it.wind_kmh) }
        return applyingHourlySupplement(items, ModelBlend.googleWeight, ModelBlend.googleHorizonHours)
    }

    private fun Forecast.applyingHourlySupplement(
        items: List<SupplementHour>,
        weight: kotlin.Double,
        horizonHours: kotlin.Double,
    ): Forecast {
        if (items.isEmpty() || hourly.isEmpty() || weight <= 0.0) return this
        val byHour = items.associateBy { kotlin.math.round(it.epoch / 3600.0).toLong() * 3600L }
        val baseWeight = 1.0 - weight
        val cutoff = current.time + horizonHours * 3600.0
        var changed = false
        val touchedHours = mutableSetOf<Long>()
        val copy = deepCopy()
        copy.hourly = hourly.map { hour ->
            if (hour.time > cutoff) return@map hour
            val g = byHour[kotlin.math.round(hour.time / 3600.0).toLong() * 3600L] ?: return@map hour
            val h = hour.copy()
            h.temperature = baseWeight * h.temperature + weight * g.temp
            val dp = h.dewPoint; val gdp = g.dewPoint
            if (dp != null && gdp != null) h.dewPoint = minOf(h.temperature, baseWeight * dp + weight * gdp)
            val w = h.windSpeed; val gw = g.windKmh
            if (w != null && gw != null) h.windSpeed = maxOf(0.0, baseWeight * w + weight * gw)
            touchedHours.add(hour.time.toLong())
            changed = true
            h
        }
        if (!changed) return this
        val hiAllow = if (extremesIncludePeak == true) ModelBlend.highAllowance else 0.0
        val loAllow = if (extremesIncludePeak == true) ModelBlend.lowAllowance else 0.0
        copy.daily = copy.daily.map { day ->
            val hrs = copy.hoursOn(day)
            if (hrs.size < 18) return@map day
            val touched = hrs.count { touchedHours.contains(it.time.toLong()) }
            if (touched == 0) return@map day
            val omShare = 1.0 - weight * (touched.toDouble() / hrs.size)
            val lift = day.phaseHighLift?.let { it * omShare }
            val drop = day.phaseLowDrop?.let { it * omShare }
            day.copy(
                phaseHighLift = lift,
                phaseLowDrop = drop,
                high = hrs.maxOf { it.temperature } + (lift ?: 0.0) + hiAllow,
                low = hrs.minOf { it.temperature } - (drop ?: 0.0) - loAllow,
            )
        }
        if (current.time <= cutoff) {
            interpolatedSupplement(items, current.time)?.let { (gTemp, gWind) ->
                copy.current.temperature = baseWeight * copy.current.temperature + weight * gTemp
                val w = copy.current.windSpeed
                if (w != null && gWind != null) {
                    copy.current.windSpeed = maxOf(0.0, baseWeight * w + weight * gWind)
                }
            }
        }
        return copy.withStandardFeelsLike()
    }

    private fun interpolatedSupplement(hours: List<SupplementHour>, time: Epoch): Pair<kotlin.Double, kotlin.Double?>? {
        val sorted = hours.sortedBy { it.epoch }
        val first = sorted.firstOrNull() ?: return null
        val last = sorted.last()
        if (time < first.epoch - 1800.0 || time > last.epoch + 1800.0) return null
        if (time <= first.epoch) return first.temp to first.windKmh
        if (time >= last.epoch) return last.temp to last.windKmh
        val afterIdx = sorted.indexOfFirst { it.epoch >= time }
        if (afterIdx <= 0) return first.temp to first.windKmh
        val a = sorted[afterIdx - 1]; val b = sorted[afterIdx]
        val span = b.epoch - a.epoch
        val f = if (span > 0) (time - a.epoch) / span else 0.0
        val t = a.temp + (b.temp - a.temp) * f
        val w = if (a.windKmh != null && b.windKmh != null) a.windKmh + (b.windKmh - a.windKmh) * f else a.windKmh ?: b.windKmh
        return t to w
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
                    val decoded = relayJson.decodeFromString(RelayWeights.serializer(), conn.inputStream.bufferedReader().readText())
                    decoded.diurnal_bias_3h?.takeIf { it.size == 8 }?.let { ModelBlend.setDiurnalBias(it, target) }
                    val w = decoded.weights
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
            val out = if (n != null && n == 3 && w != null && raw != null) {
                val ens = (w.toDouble() / n.toDouble()) * 100.0
                h.copy(precipitationProbability = (0.6 * raw + 0.4 * ens).roundToInt().toDouble())
            } else h.copy()
            out.apply { promoteLikelyPrecipitation() }
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
        val mosmixTask = async { mosmixHourly(target) }
        val base = forecastProvider.forecast(target, regionalWeights = { weightsTask.await() }) { observed?.blendAnchor }
        observed?.let { ObservationMemory.remember(target, it) }
        // Same order as the app's main screen, so widgets and saved places match it.
        base.applyingMosmixHourly(mosmixTask.await()).applyingGoogleHourly(googleTask.await()).applying(observed).applyingRadar(radar).applyingRadarNowcast(ncTask.await(), radar).calibratingEnsemblePop().agreeingNowWithNowcast()
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
