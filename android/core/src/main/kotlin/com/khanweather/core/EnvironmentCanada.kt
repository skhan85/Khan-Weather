package com.khanweather.core

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import java.time.ZoneOffset

private suspend fun <T> tryOrNull(block: suspend () -> T?): T? = try { block() } catch (e: Exception) {
    if (e is kotlinx.coroutines.CancellationException) throw e
    null
}

object ECCC {
    fun mightBeInCanada(c: Coordinate): Boolean = c.latitude in 41.5..84.0 && c.longitude in -141.5..-52.0

    /** Every leaf looks like {"en": …, "fr": …}. */
    fun en(value: JsonElement?): JsonElement? {
        val o = value as? JsonObject ?: return value
        return o["en"] ?: o.values.firstOrNull()
    }

    /** Reads {"value": {"en": 4.0}} or {"en": 4.0}, as a number or numeric string. */
    fun number(value: JsonElement?): Double? {
        var leaf = value
        (value as? JsonObject)?.get("value")?.let { leaf = it }
        return en(leaf).num
    }

    /** "43.68N" / "79.63W" → signed degrees. */
    fun coordinate(lat: JsonElement?, lon: JsonElement?): Coordinate? {
        fun degrees(any: JsonElement?, negative: Char): Double? {
            var s = any.str?.trim()?.uppercase() ?: return null
            if (s.isEmpty()) return null
            var sign = 1.0
            val last = s.last()
            if (last.isLetter()) {
                if (last == negative || (negative == 'W' && last == 'O')) sign = -1.0
                s = s.dropLast(1)
            }
            return s.toDoubleOrNull()?.let { it * sign }
        }
        val la = degrees(lat, 'S') ?: return null
        val lo = degrees(lon, 'W') ?: return null
        return Coordinate(la, lo)
    }

    fun pointCoordinate(geometry: JsonElement?): Coordinate? {
        val c = geometry["coordinates"].arr ?: return null
        if (c.size < 2) return null
        val lon = c[0].numOnly ?: return null
        val lat = c[1].numOnly ?: return null
        return Coordinate(lat, lon)
    }

    /** Maps Environment Canada's English condition text ("Light Rain", "Mostly Cloudy"). */
    fun condition(raw: String): WeatherCondition? {
        val text = raw.lowercase()
        if (text.isEmpty() || text.contains("not observed")) return null
        return when {
            text.contains("thunder") -> if (text.contains("hail")) WeatherCondition.thunderstormHail else WeatherCondition.thunderstorm
            text.contains("hail") || text.contains("ice pellet") -> WeatherCondition.thunderstormHail
            text.contains("freezing drizzle") -> WeatherCondition.freezingDrizzle
            text.contains("freezing rain") -> WeatherCondition.freezingRain
            text.contains("drizzle") -> WeatherCondition.drizzle
            text.contains("snow grains") || text.contains("ice crystals") -> WeatherCondition.snowGrains
            text.contains("flurr") || text.contains("snow shower") || text.contains("snowshower") -> WeatherCondition.snowShowers
            text.contains("snow") -> WeatherCondition.snow
            text.contains("rain shower") || text.contains("rainshower") || text.contains("shower") -> WeatherCondition.rainShowers
            text.contains("rain") || text.contains("precipitation") -> WeatherCondition.rain
            text.contains("fog") || text.contains("mist") || text.contains("haze") || text.contains("smoke") -> WeatherCondition.fog
            text.contains("mainly sunny") || text.contains("mainly clear") -> WeatherCondition.mainlyClear
            text.contains("sunny") || text.contains("clear") -> WeatherCondition.clear
            text.contains("mostly cloudy") || text.contains("cloudy periods") -> WeatherCondition.mostlyCloudy
            text.contains("partly") || text.contains("a few clouds") -> WeatherCondition.partlyCloudy
            text.contains("cloud") || text.contains("overcast") -> WeatherCondition.overcast
            else -> null
        }
    }

    fun bbox(vararg v: Double, digits: Int = 3): String = v.joinToString(",") { fmt("%.${digits}f", it) }

    fun feelsFrom(t: Double, wind: Double?, dew: Double?): Pair<Double?, FeelsLikeKind?> {
        FeelsLike.windChill(t, wind)?.let { return it to FeelsLikeKind.windChill }
        FeelsLike.humidex(t, dew)?.let { return it to FeelsLikeKind.humidex }
        return null to null
    }
}

/**
 * Observed current conditions from ECCC's city pages (collection `citypageweather-realtime`).
 * Free, no key. Canada only.
 */
class EnvironmentCanadaProvider(
    private val baseURL: String = "https://api.weather.gc.ca/collections/citypageweather-realtime/items",
    private val loader: HttpLoader = defaultLoader,
) : ObservationProvider {
    var maxStationDistanceKm = 60.0
    var maxAge = 3.0 * 3600

    override suspend fun observation(near: Coordinate): Observation? {
        if (!ECCC.mightBeInCanada(near)) return null
        for (span in listOf(0.6, 2.0)) {
            val data = loader.fetch(url(near, span), timeoutSeconds = 8)
            parse(data, near, nowEpoch(), maxStationDistanceKm, maxAge)?.let { return it }
        }
        return null
    }

    fun url(c: Coordinate, span: Double): String = buildUrl(baseURL,
        "f" to "json", "lang" to "en",
        "bbox" to ECCC.bbox(c.longitude - span * 1.5, c.latitude - span, c.longitude + span * 1.5, c.latitude + span),
        "limit" to "10")

    companion object {
        fun parse(data: ByteArray, near: Coordinate, now: Epoch, maxDistanceKm: Double, maxAge: Double): Observation? {
            val features = parseJson(data)["features"].arr ?: throw ForecastException("missing features")
            val candidates = mutableListOf<Observation>()
            for (feature in features) {
                val current = feature["properties"]["currentConditions"].obj ?: continue
                val observation = observation(current) ?: continue
                if (now - observation.observedAt > maxAge) continue
                val station = current["station"]
                val stationCoordinate = ECCC.coordinate(ECCC.en(station["lat"]), ECCC.en(station["lon"]))
                    ?: ECCC.pointCoordinate(feature["geometry"]) ?: continue
                val distance = distanceKm(near, stationCoordinate)
                if (distance > maxDistanceKm) continue
                observation.distanceKm = distance
                if (candidates.none { it.stationName == observation.stationName }) candidates.add(observation)
            }
            val chosen = choose(candidates) ?: return null
            // Every other city-page station within reach that reports drizzle or rain.
            for (other in candidates) {
                if (other.stationName != chosen.stationName) chosen.noteDrizzle(other.stationName, other.distanceKm, other.condition, other.observedAt, now)
            }
            return chosen
        }

        /** Automatic stations report temperature and wind but no sky; take the sky from the nearest that does. */
        fun choose(candidates: List<Observation>): Observation? {
            val sorted = candidates.sortedBy { it.distanceKm ?: 0.0 }
            val nearest = sorted.firstOrNull() ?: return null
            if (nearest.conditionText != null) return nearest
            val withSky = sorted.firstOrNull { it.conditionText != null } ?: return nearest
            if (!nearest.isLocal) return withSky
            return nearest.copy(condition = withSky.condition, conditionText = withSky.conditionText)
        }

        fun observation(current: JsonObject): Observation? {
            val temperature = ECCC.number(current["temperature"]) ?: return null
            val timestamp = ECCC.en(current["timestamp"]).str ?: return null
            val observedAt = parseIsoDate(timestamp) ?: return null
            val station = current["station"]
            val stationName = ECCC.en(station["value"]).str ?: ECCC.en(station).str ?: "Nearby station"
            val wind = current["wind"]
            val windSpeed = ECCC.number(wind["speed"])
            // Work feels-like out from the measurements ourselves.
            val (feels, kind) = ECCC.feelsFrom(temperature, windSpeed, ECCC.number(current["dewpoint"]))
            val text = ECCC.en(current["condition"]).str?.trim()
            return Observation(
                stationName = stationName, observedAt = observedAt, temperature = temperature,
                feelsLike = feels, feelsLikeKind = kind,
                humidity = ECCC.number(current["relativeHumidity"]),
                windSpeed = windSpeed, windDirection = ECCC.number(wind["bearing"]),
                windGusts = ECCC.number(wind["gust"]),
                condition = text?.let { ECCC.condition(it) },
                conditionText = if (text.isNullOrEmpty()) null else text,
            )
        }
    }
}

/**
 * Automatic station readings from ECCC's SWOB feed (`swob-realtime`), including partner networks
 * such as Ontario MTO road weather stations.
 */
class SWOBProvider(
    private val baseURL: String = "https://api.weather.gc.ca/collections/swob-realtime/items",
    private val loader: HttpLoader = defaultLoader,
) : ObservationProvider {
    var maxStationDistanceKm = Observation.localRadiusKm
    var maxAge = 90.0 * 60

    override suspend fun observation(near: Coordinate): Observation? {
        if (!ECCC.mightBeInCanada(near)) return null
        val now = nowEpoch()
        return parse(loader.fetch(url(near, now), timeoutSeconds = 8), near, now, maxStationDistanceKm, maxAge)
    }

    fun url(c: Coordinate, now: Epoch): String = buildUrl(baseURL,
        "f" to "json",
        "bbox" to ECCC.bbox(c.longitude - 0.28, c.latitude - 0.2, c.longitude + 0.28, c.latitude + 0.2),
        "datetime" to isoString(now - maxAge) + "/..",
        "_is-minutely_obs-value" to "false",
        "sortby" to "-obs_date_tm",
        "limit" to "120")

    companion object {
        fun parse(data: ByteArray, near: Coordinate, now: Epoch, maxDistanceKm: Double, maxAge: Double): Observation? {
            val features = parseJson(data)["features"].arr ?: throw ForecastException("missing features")
            val newest = linkedMapOf<String, Observation>()
            for (feature in features) {
                val p = feature["properties"].obj ?: continue
                val station = ECCC.pointCoordinate(feature["geometry"]) ?: continue
                val o = observation(p) ?: continue
                if (now - o.observedAt > maxAge) continue
                val distance = distanceKm(near, station)
                if (distance > maxDistanceKm) continue
                o.distanceKm = distance
                val key = p["msc_id-value"].str ?: o.stationName
                val existing = newest[key]
                if (existing != null && existing.observedAt >= o.observedAt) continue
                newest[key] = o
            }
            return newest.values.minByOrNull { it.distanceKm ?: 0.0 }
        }

        fun observation(p: JsonObject): Observation? {
            val t = p["air_temp"].num ?: return null
            if (t !in -60.0..50.0) return null
            val stamp = p["obs_date_tm"].str ?: return null
            val observedAt = parseIsoDate(stamp) ?: return null
            val name = p["stn_nam-value"].str?.trim() ?: "Nearby station"
            if (name.uppercase().contains("TEST")) return null
            val wind = firstValue(p, listOf("avg_wnd_spd_10m_pst10mts", "avg_wnd_spd_10m_pst2mts", "avg_wnd_spd_10m_pst1mt", "avg_wnd_spd"))
                ?.takeIf { it in 0.0..250.0 }
            val gusts = firstValue(p, listOf("max_wnd_spd_10m_pst1hr", "max_wnd_spd_10m_pst10mts", "max_wnd_spd_pst1hr", "max_wnd_spd"))
                ?.takeIf { it in 0.0..300.0 }
            val direction = firstValue(p, listOf("avg_wnd_dir_10m_pst10mts", "avg_wnd_dir_10m_pst2mts", "avg_wnd_dir_10m_pst1mt", "avg_wnd_dir"))
            val humidity = p["rel_hum"].num?.takeIf { it in 0.0..100.0 }
            val rain1h = firstValue(p, listOf("pcpn_amt_pst1hr", "rnfl_amt_pst1hr"))?.takeIf { it in 0.0..200.0 }
            val (feels, kind) = ECCC.feelsFrom(t, wind, p["dwpt_temp"].num)
            return Observation(
                stationName = name, observedAt = observedAt, temperature = t, feelsLike = feels, feelsLikeKind = kind,
                humidity = humidity, windSpeed = wind, windDirection = direction, windGusts = gusts,
                rainGauges = rain1h?.let { 1 }, rainLastHourMm = rain1h,
                dataProvider = p["data_pvdr-value"].str,
            )
        }

        /** Exact key first, then any key starting with the prefix that isn't a -uom/-qa sibling. */
        fun firstValue(p: JsonObject, prefixes: List<String>): Double? {
            for (prefix in prefixes) p[prefix].num?.let { return it }
            for (prefix in prefixes) {
                for (key in p.keys.sorted()) {
                    if (key.startsWith(prefix) && !key.contains("-")) p[key].num?.let { return it }
                }
            }
            return null
        }
    }
}

/**
 * Partner stations (e.g. Ontario MTO road weather stations) published on ECCC's Datamart as
 * SWOB-ML files but not in the `swob-realtime` API. CR-27 Campbellville is one.
 */
class PartnerStationProvider(
    private val stationsURL: String = "https://api.weather.gc.ca/collections/swob-partner-stations/items",
    private val datamartURL: String = "https://dd.weather.gc.ca/today/observations/swob-ml/partners/",
    private val loader: HttpLoader = defaultLoader,
) : ObservationProvider {
    var maxStationDistanceKm = Observation.localRadiusKm
    var maxAge = 90.0 * 60

    data class Station(val name: String, val folder: String, val id: String, val coordinate: Coordinate, val distanceKm: Double)

    override suspend fun observation(near: Coordinate): Observation? {
        if (!ECCC.mightBeInCanada(near)) return null
        val query = buildUrl(stationsURL, "f" to "json",
            "bbox" to ECCC.bbox(near.longitude - 0.28, near.latitude - 0.2, near.longitude + 0.28, near.latitude + 0.2),
            "limit" to "100")
        val stations = parseStations(loader.fetch(query, timeoutSeconds = 6), near, maxStationDistanceKm)
        val candidates = stations.take(3)
        if (candidates.isEmpty()) return null
        val now = nowEpoch()
        return coroutineScope {
            candidates.map { station ->
                async {
                    tryOrNull { latest(station, now) }?.also { it.distanceKm = station.distanceKm }
                }
            }.mapNotNull { it.await() }.firstOrNull()
        }
    }

    private suspend fun latest(station: Station, now: Epoch): Observation? {
        for (day in listOf(now, now - 86400)) {
            val folder = datamartURL + station.folder + "/" + dayString(day) + "/" + station.id + "/"
            val listing = tryOrNull { loader.fetch(folder, timeoutSeconds = 6) } ?: continue
            val file = newestFile(listing.decodeToString()) ?: continue
            val o = parseSWOBML(loader.fetch(folder + file, timeoutSeconds = 6).decodeToString()) ?: return null
            if (now - o.observedAt > maxAge) return null
            return o
        }
        return null
    }

    companion object {
        fun dayString(t: Epoch): String {
            val d = Instant.ofEpochSecond(t.toLong()).atZone(ZoneOffset.UTC).toLocalDate()
            return fmt("%04d%02d%02d", d.year, d.monthValue, d.dayOfMonth)
        }

        fun parseStations(data: ByteArray, near: Coordinate, maxDistanceKm: Double): List<Station> {
            val features = parseJson(data)["features"].arr ?: throw ForecastException("missing features")
            val out = mutableListOf<Station>()
            for (feature in features) {
                val p = feature["properties"].obj ?: continue
                val point = ECCC.pointCoordinate(feature["geometry"]) ?: continue
                val iata = (p["iata_id"] ?: p["iata"]).str ?: continue
                if (iata.isEmpty()) continue
                val msc = (p["msc_id"] ?: p["msc_id-value"]).str ?: continue
                val folder = partnerFolder(msc) ?: continue
                val name = (p["name_en"] ?: p["name"]).str ?: iata
                if (name.uppercase().contains("TEST")) continue
                val distance = distanceKm(near, point)
                if (distance > maxDistanceKm) continue
                out.add(Station(name, folder, iata.lowercase(), point, distance))
            }
            return out.sortedBy { it.distanceKm }
        }

        /** "ON_MTO_CR-27" → "on-mto". */
        fun partnerFolder(mscID: String): String? {
            val parts = mscID.split("_")
            if (parts.size < 3) return null
            return "${parts[0]}-${parts[1]}".lowercase()
        }

        fun newestFile(html: String): String? =
            Regex("href=\"([^\"/]+-swob\\.xml)\"").findAll(html).map { it.groupValues[1] }.maxOrNull()

        /** SWOB-ML: `<element name="air_temp" value="4.4">` with a `qa_summary` qualifier (100 = passed). */
        fun parseSWOBML(xml: String): Observation? {
            val values = mutableMapOf<String, String>()
            var current: String? = null
            val tag = Regex("<\\s*(/?)\\s*([A-Za-z0-9_:.-]+)([^>]*?)(/?)>")
            val attr = Regex("([A-Za-z_:][A-Za-z0-9_:.-]*)\\s*=\\s*\"([^\"]*)\"")
            for (m in tag.findAll(xml)) {
                val closing = m.groupValues[1] == "/"
                val local = m.groupValues[2].substringAfterLast(':')
                if (closing) {
                    if (local == "element") current = null
                    continue
                }
                val attrs = attr.findAll(m.groupValues[3]).associate { it.groupValues[1] to unescape(it.groupValues[2]) }
                if (local == "element") {
                    val name = attrs["name"]
                    val value = attrs["value"]
                    if (name != null && value != null) {
                        current = name
                        if (!values.containsKey(name)) values[name] = value
                    }
                    if (m.groupValues[4] == "/") current = null
                } else if (local == "qualifier" && attrs["name"] == "qa_summary") {
                    val qa = attrs["value"]
                    val c = current
                    if (c != null && qa != null && qa != "100" && qa != "MSNG") values.remove(c)
                }
            }
            fun number(name: String): Double? = values[name]?.takeIf { it != "MSNG" }?.toDoubleOrNull()
            val t = number("air_temp")?.takeIf { it in -60.0..50.0 } ?: return null
            val observedAt = values["date_tm"]?.let { parseIsoDate(it) } ?: return null
            val wind = (number("avg_wnd_spd_10m_pst10mts") ?: number("avg_wnd_spd_10m_pst2mts") ?: number("avg_wnd_spd_10m_pst1mt"))
                ?.takeIf { it in 0.0..250.0 }
            val gusts = (number("max_wnd_spd_10m_pst1hr") ?: number("max_wnd_spd_10m_pst10mts") ?: number("max_wnd_spd_pst1hr"))
                ?.takeIf { it in 0.0..300.0 }
            val direction = number("avg_wnd_dir_10m_pst10mts") ?: number("avg_wnd_dir_10m_pst2mts") ?: number("avg_wnd_dir_10m_pst1mt")
            val humidity = number("rel_hum")?.takeIf { it in 0.0..100.0 }
            val rain1h = (number("pcpn_amt_pst1hr") ?: number("rnfl_amt_pst1hr"))?.takeIf { it in 0.0..200.0 }
            val (feels, kind) = ECCC.feelsFrom(t, wind, number("dwpt_temp"))
            return Observation(
                stationName = values["stn_nam"] ?: "Nearby station", observedAt = observedAt, temperature = t,
                feelsLike = feels, feelsLikeKind = kind, humidity = humidity, windSpeed = wind,
                windDirection = direction, windGusts = gusts,
                rainGauges = rain1h?.let { 1 }, rainLastHourMm = rain1h,
                dataProvider = values["msc_id"]?.let { partnerFolder(it) }?.uppercase(),
            )
        }

        private fun unescape(s: String) = s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
            .replace("&apos;", "'").replace("&amp;", "&")
    }
}

/**
 * Canada: temperature, wind and feels-like from the nearest SWOB station within the local radius,
 * and the sky from the nearest city-page station that reports one.
 */
class CanadaObservationProvider(
    private val local: ObservationProvider = SWOBProvider(),
    private val partners: ObservationProvider = PartnerStationProvider(),
    private val sky: ObservationProvider = EnvironmentCanadaProvider(),
) : ObservationProvider {
    override suspend fun observation(near: Coordinate): Observation? = coroutineScope {
        val nearby = async { tryOrNull { local.observation(near) } }
        val partner = async { tryOrNull { partners.observation(near) } }
        val city = async { tryOrNull { sky.observation(near) } }
        combine(nearest(nearby.await(), partner.await()), city.await())
    }

    companion object {
        fun nearest(a: Observation?, b: Observation?): Observation? {
            if (a == null) return b
            if (b == null) return a
            return if ((a.distanceKm ?: Double.POSITIVE_INFINITY) <= (b.distanceKm ?: Double.POSITIVE_INFINITY)) a else b
        }

        fun combine(local: Observation?, sky: Observation?): Observation? {
            if (local == null || !local.isLocal) return sky
            if (sky == null) return local
            if (sky.isLocal) {
                val much = (local.distanceKm ?: 0.0) + 5 < (sky.distanceKm ?: 0.0)
                if (!much) return sky
            }
            return local.copy(condition = sky.condition, conditionText = sky.conditionText,
                skyStationName = sky.stationName, skyDataProvider = sky.dataProvider, skyDistanceKm = sky.distanceKm)
                .also { it.mergeNearbyReports(sky) }
        }
    }
}

internal suspend fun <T> safely(block: suspend () -> T?): T? = tryOrNull(block)
