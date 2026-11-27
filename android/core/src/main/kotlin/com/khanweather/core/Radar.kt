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

    /** Snow at or below 1°C, rain at 3°C and above; between the two keep what the radar says. */
    fun typed(celsius: Double?): RadarNow {
        if (celsius == null || !isPrecipitating) return this
        val r = copy()
        if (celsius >= 3 && isSnowing) {
            r.rainMmPerHour = max(rainMmPerHour, snowCmPerHour)
            r.snowCmPerHour = 0.0
        } else if (celsius <= 1 && isRaining) {
            r.snowCmPerHour = max(snowCmPerHour, rainMmPerHour)
            r.rainMmPerHour = 0.0
        } else if (isSnowing && isRaining) {
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

/**
 * Rain or snow that reaches the ground moistens the air it falls through within minutes, so a radar
 * echo over air drier than this is falling apart aloft or isn't weather at all (26 Nov, 9:43 pm in
 * Milton: "moderate rain" from the radar at 73% humidity, nothing falling). Lower below -2°.
 */
fun dryAirHumidity(celsius: Double): Double = if (celsius > -2) 80.0 else 70.0

/** False when the air here is too dry for the radar's echo to be reaching the ground. */
val Forecast.radarEchoCanReachGround: Boolean
    get() {
        val rh = current.humidity ?: return true
        return rh >= dryAirHumidity(current.temperature)
    }

/** When the radar shows rain or snow falling here now, say so even if the model says cloudy. */
fun Forecast.applyingRadar(radarNow: RadarNow?): Forecast {
    val radar = radarNow?.typed(current.temperature) ?: return this
    if (radar.isPrecipitating && !radarEchoCanReachGround) return this
    // Virga guard: in dry surface air (RH < 80%), weak overhead radar (< 1.0 mm/h)
    // evaporates before reaching the ground; below 88% RH, ignore < 0.5 mm/h clutter.
    if (current.temperature >= 3.0 && radar.isPrecipitating && (radarNow?.rainMmPerHour ?: 0.0) < 0.5) return this
    val rh = current.humidity?.toDouble()
    if (rh != null && radar.isRaining && !radar.isSnowing && current.temperature > 1.0 &&
        (observation?.rainLastHourMm ?: 0.0) < 0.1 &&
        ((rh < 90.0 && radar.rainMmPerHour < 1.0) || radar.rainMmPerHour < 0.5)
    ) return this
    val condition = radar.condition
    if (condition == null) {
        if (current.temperature <= 1 || !current.condition.isRainLike || (observation?.skyIsLocal ?: false)) return this
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
