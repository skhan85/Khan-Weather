package com.khanweather.core

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max

/** What the radar sees over one point right now. */
@Serializable
data class RadarNow(
    /** Rain rate, mm/h. */
    var rainMmPerHour: Double,
    /** Snow rate, cm/h. */
    var snowCmPerHour: Double,
    val time: Epoch,
) {
    val isSnowing: Boolean get() = snowCmPerHour >= snowThreshold
    val isRaining: Boolean get() = rainMmPerHour >= rainThreshold
    val isPrecipitating: Boolean get() = isSnowing || isRaining

    /** Snow wins when both show. */
    val condition: WeatherCondition?
        get() = when {
            isSnowing -> WeatherCondition.snow
            isRaining -> if (rainMmPerHour < 0.5) WeatherCondition.drizzle else WeatherCondition.rain
            else -> null
        }

    /**
     * The rain and snow layers are the same echo read both ways, so the type comes from here: rain at
     * 3°C and above, snow at -2°C and below, in between the models' rain-or-snow vote for the hour,
     * else snow at or below 1°C. Snow takes the snow layer's rate (26 Nov, Milton: a 3.2 mm/h rain echo
     * at 0° showed as "Heavy snow" while it was raining).
     */
    fun typed(celsius: Double?, models: PrecipitationKind? = null): RadarNow {
        if (celsius == null || !isPrecipitating) return this
        val snow = when {
            celsius >= 3 -> false
            celsius <= -2 -> true
            models == PrecipitationKind.rain -> false
            models == PrecipitationKind.snow -> true
            else -> celsius <= 1
        }
        val r = copy()
        if (snow) {
            r.snowCmPerHour = if (snowCmPerHour > 0) snowCmPerHour else rainMmPerHour
            r.rainMmPerHour = 0.0
        } else {
            r.rainMmPerHour = if (rainMmPerHour > 0) rainMmPerHour else snowCmPerHour
            r.snowCmPerHour = 0.0
        }
        return r
    }

    /** "Light snow", "Moderate rain", using Environment Canada's rate bands. */
    val description: String?
        get() {
            if (isSnowing) {
                val s = snowCmPerHour
                return (if (s < 0.5) "Light" else if (s < 1) "Moderate" else "Heavy") + " snow"
            }
            if (isRaining) {
                val r = rainMmPerHour
                return (if (r < 2.5) "Light" else if (r < 7.6) "Moderate" else "Heavy") + " rain"
            }
            return null
        }

    companion object {
        const val rainThreshold = 0.1
        const val snowThreshold = 0.05
    }
}

/** Environment Canada's North American 1 km radar mosaic (MSC GeoMet WMS). */
class ECCCRadarProvider(private val loader: HttpLoader = defaultLoader) {
    private val maxAge = 30.0 * 60

    suspend fun now(coordinate: Coordinate): RadarNow? = coroutineScope {
        val rain = async { neighbourhood("RADAR_1KM_RRAI", coordinate) }
        val snow = async { neighbourhood("RADAR_1KM_RSNO", coordinate) }
        val r = rain.await()
        val s = snow.await()
        val time = listOfNotNull(r?.second, s?.second).maxOrNull() ?: return@coroutineScope null
        if (nowEpoch() - time >= maxAge) return@coroutineScope null
        RadarNow(r?.first ?: 0.0, s?.first ?: 0.0, time)
    }

    private suspend fun sample(layer: String, c: Coordinate): Pair<Double, Epoch>? = parse(loader.fetch(url(layer, c)))

    /**
     * The median of the spot and four points about 2 km around it. One bright pixel over the spot
     * (ground clutter, worst on cold, clear nights) is outvoted by its dry neighbours, while real
     * rain or snow covers all five and still counts.
     */
    private suspend fun neighbourhood(layer: String, c: Coordinate): Pair<Double, Epoch>? = coroutineScope {
        val points = neighbourhoodPoints(c)
        val centreJob = async { sample(layer, points[0]) }
        val others = points.drop(1).map { p -> async { runCatching { sample(layer, p) }.getOrNull() } }
        val centre = centreJob.await() ?: return@coroutineScope null
        val sameFrame = (listOf(centre) + others.mapNotNull { it.await() })
            .filter { abs(it.second - centre.second) < 60 }.map { it.first }
        if (sameFrame.size < 3) centre else median(sameFrame) to centre.second
    }

    companion object {
        /** Wider than one 1 km pixel, narrower than any real band of rain or snow. */
        const val neighbourOffsetKm = 2.0

        fun neighbourhoodPoints(c: Coordinate): List<Coordinate> {
            val dLat = neighbourOffsetKm / 111.0
            val dLon = neighbourOffsetKm / (111.0 * max(0.2, cos(c.latitude * PI / 180)))
            return listOf(
                c,
                Coordinate(c.latitude + dLat, c.longitude),
                Coordinate(c.latitude - dLat, c.longitude),
                Coordinate(c.latitude, c.longitude + dLon),
                Coordinate(c.latitude, c.longitude - dLon),
            )
        }

        fun median(values: List<Double>): Double {
            val v = values.sorted()
            if (v.isEmpty()) return 0.0
            return if (v.size % 2 == 1) v[v.size / 2] else (v[v.size / 2 - 1] + v[v.size / 2]) / 2
        }

        fun url(layer: String, coordinate: Coordinate): String {
            val c = coordinate.rounded
            val d = 0.01
            return buildUrl("https://geo.weather.gc.ca/geomet",
                "service" to "WMS", "version" to "1.3.0", "request" to "GetFeatureInfo",
                "layers" to layer, "query_layers" to layer, "crs" to "EPSG:4326",
                "bbox" to ECCC.bbox(c.latitude - d, c.longitude - d, c.latitude + d, c.longitude + d, digits = 4),
                "width" to "3", "height" to "3", "i" to "1", "j" to "1", "info_format" to "application/json")
        }

        fun parse(data: ByteArray): Pair<Double, Epoch>? {
            val p = parseJson(data)["features"].arr?.firstOrNull()?.get("properties") ?: return null
            val time = p["time"].str?.let { parseIsoDate(it) } ?: return null
            return (p["value"].numOnly ?: 0.0) to time
        }
    }
}

/** Radar rain lighter than this (mm/h) is overruled by dry local rain gauges. */
const val gaugeVetoRate = 1.0

/** The models' rain-or-snow call for the hour holding `time`, when that hour has rain or snow in it. */
fun Forecast.modelPrecipitationKind(time: Epoch): PrecipitationKind? {
    val h = hourly.lastOrNull { it.time <= time } ?: return null
    if (time - h.time >= 3600 || ((h.rain ?: 0.0) <= 0 && (h.snowfall ?: 0.0) <= 0)) return null
    return h.precipitationKind
}

/** A station's rain 3 km away or more loses to a dry radar over the spot (drizzle stays: radar misses it). */
const val radarBeatsStationKm = 3.0

val Forecast.skyStationBeyondRadarReach: Boolean
    get() {
        val o = observation ?: return false
        if (current.condition == WeatherCondition.drizzle || current.condition == WeatherCondition.freezingDrizzle) return false
        val km = if (o.skyStationName == null) o.distanceKm else o.skyDistanceKm
        return (km ?: 0.0) >= radarBeatsStationKm
    }

/** In air this damp (%), a light radar echo (0.1-0.5 mm/h) is reaching the ground. */
const val dampEchoHumidity = 90.0

/** Air this damp (%) under low cloud can drizzle. */
const val drizzleHumidity = 88.0

/** Drizzle in damp air: radar beams pass over the low cloud it falls from, so a dry radar doesn't overrule it. */
val Forecast.drizzleRadarCantSee: Boolean
    get() {
        if (current.condition != WeatherCondition.drizzle && current.condition != WeatherCondition.freezingDrizzle) return false
        return (current.humidity?.toDouble() ?: 0.0) >= drizzleHumidity || observation?.nearbyDrizzleStation != null
    }

/** When the radar shows rain or snow falling here now, say so even if the model says cloudy. */
fun Forecast.applyingRadar(radarNow: RadarNow?): Forecast {
    val radar = radarNow?.typed(current.temperature, modelPrecipitationKind(current.time)) ?: return this
    // Virga guard: in dry surface air, weak overhead radar (< 1.0 mm/h) evaporates before reaching
    // the ground, and below 0.5 mm/h it can be clutter. In saturated air (RH >= 90%) nothing evaporates
    // on the way down: a light echo there is drizzle or light rain, so it counts.
    val damp = (current.humidity?.toDouble() ?: 0.0) >= dampEchoHumidity
    if (current.temperature >= 3.0 && !damp && radar.isPrecipitating &&
        (radar.rainMmPerHour < 0.5 || (radarNow?.rainMmPerHour ?: 0.0) < 0.5)) return this
    val rh = current.humidity?.toDouble()
    if (rh != null && radar.isRaining && !radar.isSnowing && current.temperature > 1.0 &&
        (observation?.rainLastHourMm ?: 0.0) < 0.1 &&
        ((rh < 90.0 && radar.rainMmPerHour < 1.0) || (!damp && radar.rainMmPerHour < 0.5))
    ) return this
    val condition = radar.condition
    if (condition == null) {
        if (current.temperature <= 1 || !current.condition.isRainLike ||
            ((observation?.skyIsLocal ?: false) && !skyStationBeyondRadarReach) || drizzleRadarCantSee) return this
        val copy = deepCopy()
        copy.current.condition = WeatherCondition.overcast
        copy.observation?.conditionText = null
        copy.skySource = "radar over this spot (dry)"
        return copy
    }
    if (observation?.gaugesSayDry == true && !radar.isSnowing && radar.rainMmPerHour < gaugeVetoRate) return this
    val copy = deepCopy()
    copy.current.condition = condition
    copy.observation?.conditionText = radar.description
    copy.radar = radar
    copy.skySource = "radar over this spot"
    return copy
}
