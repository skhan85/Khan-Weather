package com.khanweather.core

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** A real measurement from a weather station, as opposed to a model estimate. */
@Serializable
data class Observation(
    var stationName: String,
    var observedAt: Epoch,
    var temperature: Double,
    var feelsLike: Double? = null,
    var feelsLikeKind: FeelsLikeKind? = null,
    var humidity: Double? = null,
    var windSpeed: Double? = null,
    var windDirection: Double? = null,
    var windGusts: Double? = null,
    var condition: WeatherCondition? = null,
    var conditionText: String? = null,
    var distanceKm: Double? = null,
    /** Who runs the station when it isn't ECCC itself, e.g. "ON-MTO" or "NETATMO". */
    var dataProvider: String? = null,
    /** When the sky (condition) came from a different station than the readings. */
    var skyStationName: String? = null,
    var skyDataProvider: String? = null,
    var skyDistanceKm: Double? = null,
    var rainGauges: Int? = null,
    var rainLastHourMm: Double? = null,
    /** Home stations only: each nearby station's reading, nearest first. */
    var stationTemperatures: List<Double>? = null,
    /** A station or airport within `drizzleReachKm` reporting drizzle (radar can't see it). */
    var nearbyDrizzleStation: String? = null,
    var nearbyDrizzleKm: Double? = null,
) {
    /** Notes another report's drizzle when it is close enough to count. */
    fun noteDrizzle(station: String, km: Double?, condition: WeatherCondition?, observedAt: Epoch? = null, now: Epoch = nowEpoch()) {
        if (nearbyDrizzleStation != null || (condition != WeatherCondition.drizzle && condition != WeatherCondition.freezingDrizzle)) return
        if (km == null || km > drizzleReachKm) return
        if (observedAt != null && now - observedAt > 5400) return
        nearbyDrizzleStation = WeatherFormat.plainStationName(station)
        nearbyDrizzleKm = km
    }

    /** Whether the sky (rain, snow, cloud) was reported within `localRadiusKm`. */
    val skyIsLocal: Boolean
        get() = if (skyStationName == null) isLocal else (skyDistanceKm ?: Double.POSITIVE_INFINITY) <= localRadiusKm

    /** Local gauges report and none caught a drop in the last hour. */
    val gaugesSayDry: Boolean get() = (rainGauges ?: 0) > 0 && (rainLastHourMm ?: 1.0) == 0.0

    val isLocal: Boolean get() = (distanceKm ?: 0.0) <= localRadiusKm

    /** The temperature that may re-weight the first hours of the model blend. */
    val blendAnchor: ModelBlend.Anchor?
        get() = if (!isLocal || !temperature.isFinite()) null else ModelBlend.Anchor(temperature, observedAt, dataProvider == "NETATMO")

    /**
     * Home stations wobble by a few tenths; averages this reading with the previous one for the
     * same spot when that one is recent and close. Official stations are left alone.
     */
    fun smoothed(previous: Observation?, now: Epoch = nowEpoch()): Observation {
        if (previous == null || dataProvider != "NETATMO" || previous.dataProvider != "NETATMO" ||
            now - previous.observedAt >= smoothingWindow || abs(temperature - previous.temperature) >= smoothingLimit) return this
        return copy(temperature = ((temperature + previous.temperature) / 2 * 10).rnd() / 10)
    }

    companion object {
        /** Stations closer than this stand in for the user's own spot. */
        const val localRadiusKm = 10.0
        const val drizzleReachKm = 40.0
        const val smoothingWindow = 45.0 * 60
        const val smoothingLimit = 1.5
    }
}

interface ObservationProvider {
    suspend fun observation(near: Coordinate): Observation?
}

fun distanceKm(a: Coordinate, b: Coordinate): Double {
    val r = 6371.0
    val dLat = (b.latitude - a.latitude) * Math.PI / 180
    val dLon = (b.longitude - a.longitude) * Math.PI / 180
    val h = sin(dLat / 2) * sin(dLat / 2) +
        cos(a.latitude * Math.PI / 180) * cos(b.latitude * Math.PI / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1.0, sqrt(h)))
}

/** By day, home stations more than this above the forecast are taken to be in the sun. */
private const val sunWarmLimit = 2.5
/** At night, a home station more than this above the forecast is taken to be by a warm wall. */
private const val nightWarmLimit = 4.0
/** How long a station reading keeps pulling the forecast toward it. */
private const val nudgeHours = 6.0

fun median(values: List<Double>): Double? {
    if (values.isEmpty()) return null
    val v = values.sorted()
    return if (v.size % 2 == 1) v[v.size / 2] else (v[v.size / 2 - 1] + v[v.size / 2]) / 2
}

/**
 * Replaces the model's "now" with a station observation where the station has data, and eases
 * the next few forecast hours toward it.
 */
fun Forecast.applying(observation: Observation?): Forecast {
    val o = observation?.copy() ?: return this
    val copy = deepCopy()
    val c = current.copy()
    // A sky reported by a station far away says nothing about the sky here.
    if (!o.skyIsLocal) {
        o.noteDrizzle(o.skyStationName ?: o.stationName, if (o.skyStationName == null) o.distanceKm else o.skyDistanceKm, o.condition)
        o.condition = null
        o.conditionText = null
    }
    copy.observation = o
    if (o.condition != null) {
        val name = o.skyStationName ?: o.stationName
        val km = if (o.skyStationName == null) o.distanceKm else o.skyDistanceKm
        copy.skySource = WeatherFormat.plainStationName(name) +
            (km?.let { ", ${WeatherFormat.roughDistance(it)} away" } ?: "")
    }
    // A home sensor in the sun can read 5-13° high; by day drop stations well above the forecast.
    val temps = o.stationTemperatures
    if (o.dataProvider == "NETATMO" && temps != null && temps.isNotEmpty()) {
        val limit = if (current.isDay) sunWarmLimit else nightWarmLimit
        val shaded = temps.filter { it <= current.temperature + limit }
        if (shaded.isEmpty()) {
            o.temperature = Double.POSITIVE_INFINITY
        } else if (shaded.size < temps.size) {
            val mid = median(shaded.take(3))
            if (mid != null) o.temperature = (mid * 10).rnd() / 10
        }
    }
    val pwsLimit = if ((o.stationTemperatures?.size ?: 0) >= 2) 5.0 else 2.5
    val implausible = o.dataProvider == "NETATMO" && !(abs(o.temperature - current.temperature) <= pwsLimit)
    if (!o.isLocal || implausible) {
        c.condition = o.condition ?: c.condition
        copy.current = c
        return copy.dryIfGaugesSay(o)
    }
    c.temperature = o.temperature
    // Wind chill from the stronger of the station's wind and the forecast wind for this spot.
    val chillWind = max(o.windSpeed ?: 0.0, current.windSpeed ?: 0.0)
    val chill = FeelsLike.windChill(o.temperature, chillWind)
    val feels = o.feelsLike
    val kind = o.feelsLikeKind
    if (chill != null) {
        c.feelsLike = chill
        c.feelsLikeKind = FeelsLikeKind.windChill
    } else if (feels != null && kind != null && kind != FeelsLikeKind.windChill) {
        c.feelsLike = feels
        c.feelsLikeKind = kind
    } else {
        c.feelsLike = o.temperature
    }
    c.humidity = o.humidity ?: c.humidity
    c.windSpeed = o.windSpeed ?: c.windSpeed
    c.windGusts = o.windGusts ?: c.windGusts
    c.windDirection = o.windDirection ?: c.windDirection
    o.rainLastHourMm?.let { c.precipitation = it }
    c.condition = o.condition ?: c.condition
    c.time = o.observedAt
    copy.current = c
    copy.hourly = nudged(o)
    copy.daily = copy.dailyIncluding(c, o.observedAt)
    return copy.dryIfGaugesSay(o)
}

/** Rain from a distant station or the model, when the rain gauges here are dry, becomes cloud. */
fun Forecast.dryIfGaugesSay(o: Observation): Forecast {
    if (!o.gaugesSayDry || current.temperature <= 1 || !current.condition.isRainLike) return this
    val copy = deepCopy()
    copy.current.condition = WeatherCondition.overcast
    copy.observation?.conditionText = null
    return copy
}

/** Today's high and low widened to take in the reading and the eased hours. */
fun Forecast.dailyIncluding(now: CurrentConditions, time: Epoch): List<DailyForecast> = daily.map { day ->
    val hours = hoursOn(day)
    if (hours.none { abs(it.time - time) < 3600 }) return@map day
    val d = day.copy()
    val temps = hours.map { it.temperature } + now.temperature
    val feels = hours.mapNotNull { it.feelsLike } + now.feelsLike
    if (hours.size >= 18) {
        val hiAllow = if (extremesIncludePeak == true) ModelBlend.highAllowance else 0.0
        val loAllow = if (extremesIncludePeak == true) ModelBlend.lowAllowance else 0.0
        d.high = max(hours.maxOf { it.temperature } + hiAllow, now.temperature)
        d.low = min(hours.minOf { it.temperature } - loAllow, now.temperature)
        if (d.feelsLikeHigh != null) d.feelsLikeHigh = feels.max()
        if (d.feelsLikeLow != null) d.feelsLikeLow = feels.min()
    } else {
        d.high = max(d.high, temps.max())
        d.low = min(d.low, temps.min())
        d.feelsLikeHigh = d.feelsLikeHigh?.let { max(it, feels.max()) }
        d.feelsLikeLow = d.feelsLikeLow?.let { min(it, feels.min()) }
    }
    d
}

/** Linearly interpolates a numeric hourly field at `time`. */
private fun Forecast.forecastValue(time: Epoch, extract: (HourlyForecast) -> Double?): Double? {
    val i = hourly.indexOfLast { it.time <= time }
    if (i < 0) return hourly.firstOrNull()?.let(extract)
    val a = hourly[i]
    val va = extract(a) ?: return null
    if (i + 1 >= hourly.size) return va
    val vb = extract(hourly[i + 1]) ?: return va
    val span = hourly[i + 1].time - a.time
    if (span <= 0) return va
    val f = min(1.0, max(0.0, (time - a.time) / span))
    return va + (vb - va) * f
}

/** The hourly forecast's temperature at `time`, read between the two hours around it. */
fun Forecast.forecastTemperature(time: Epoch): Double? = forecastValue(time) { it.temperature }

/**
 * Nudges temperature, feels-like, dew point, humidity and wind over the next `nudgeHours`
 * toward the observation, so the hourly curve starts where the station is.
 */
fun Forecast.nudged(observation: Observation): List<HourlyForecast> {
    val time = observation.observedAt
    val baseTemp = forecastTemperature(time) ?: return hourly
    val tempGap = observation.temperature - baseTemp

    val obsHumidity = observation.humidity?.let { min(100.0, max(0.0, it)) }
    val obsDewPoint = obsHumidity?.let { FeelsLike.dewPoint(observation.temperature, it) }
    val baseHumidity = forecastValue(time) { it.humidity }
    val baseDewPoint = forecastValue(time) { it.dewPoint }
    val humidityGap = if (obsHumidity != null && baseHumidity != null) obsHumidity - baseHumidity else null
    val dewPointGap = if (obsDewPoint != null && baseDewPoint != null) obsDewPoint - baseDewPoint else null

    // Home wind sensors are usually sheltered and read low, so only an official station's wind steers.
    val officialWind = observation.dataProvider != "NETATMO"
    val baseWind = forecastValue(time) { it.windSpeed }
    val windGap = if (officialWind && observation.windSpeed != null && baseWind != null) observation.windSpeed!! - baseWind else null
    val baseGusts = forecastValue(time) { it.windGusts }
    val gustsGap = if (officialWind && observation.windGusts != null && baseGusts != null) observation.windGusts!! - baseGusts else null

    return hourly.map { hour ->
        val hoursAhead = (hour.time - time) / 3600
        if (hoursAhead <= -1) return@map hour
        val share = max(0.0, 1 - max(hoursAhead, 0.0) / nudgeHours)
        if (share <= 0) return@map hour
        val h = hour.copy()
        h.temperature += tempGap * share
        h.feelsLike = h.feelsLike?.let { it + tempGap * share }
        h.modelLow = h.modelLow?.let { it + tempGap * share }
        h.modelHigh = h.modelHigh?.let { it + tempGap * share }
        val dp = h.dewPoint
        val hum = h.humidity
        if (dewPointGap != null && dp != null) {
            val nudgedDP = min(h.temperature, dp + dewPointGap * share)
            h.dewPoint = nudgedDP
            h.humidity = FeelsLike.relativeHumidity(h.temperature, nudgedDP)
        } else if (humidityGap != null && hum != null) {
            val nudgedHum = min(100.0, max(0.0, hum + humidityGap * share))
            h.humidity = nudgedHum
            if (h.dewPoint != null) h.dewPoint = FeelsLike.dewPoint(h.temperature, nudgedHum)
        }
        val w = h.windSpeed
        if (windGap != null && w != null) h.windSpeed = max(0.0, w + windGap * share)
        val g = h.windGusts
        if (gustsGap != null && g != null) h.windGusts = max(h.windSpeed ?: 0.0, g + gustsGap * share)
        h
    }
}
