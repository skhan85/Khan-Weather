package com.khanweather.core

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlin.math.abs
import kotlin.math.max

/** Rough boxes to decide which national services to ask. */
object Region {
    fun inUS(c: Coordinate): Boolean =
        (c.latitude in 24.0..50.0 && c.longitude in -125.0..-66.0) ||
            (c.latitude in 51.0..72.0 && c.longitude in -170.0..-129.0) ||
            (c.latitude in 18.0..23.0 && c.longitude in -161.0..-154.0)

    fun inGermany(c: Coordinate): Boolean = c.latitude in 47.2..55.1 && c.longitude in 5.8..15.1
    fun inCanada(c: Coordinate): Boolean = c.latitude in 41.6..84.0 && c.longitude in -141.0..-52.0
    fun inEuropeNational(c: Coordinate): Boolean = c.latitude in 45.7..70.1 && c.longitude in 5.9..31.6 && !inGermany(c)
}

/** Netatmo personal weather stations, served by the family relay (it holds the Netatmo key). */
class NetatmoRelayProvider(
    private val baseURL: String = defaultBaseURL,
    private val loader: HttpLoader = defaultLoader,
) : ObservationProvider {
    val radiusKm = 8.0
    val maxAge = 3600.0

    override suspend fun observation(near: Coordinate): Observation? {
        val url = buildUrl(baseURL, "lat" to fmt("%.4f", near.latitude), "lon" to fmt("%.4f", near.longitude))
        return parse(loader.fetch(url, timeoutSeconds = 8), near, nowEpoch(), radiusKm, maxAge)
    }

    companion object {
        const val defaultBaseURL = "https://weather-relay.khanofmilton.ca/v1/netatmo"
        const val fillRadiusKm = 10.0
        const val outlierLimit = 2.5

        private class S(val temperature: Double?, val humidity: Double?, val city: String?, val rain: Double?,
                        val wind: Double?, val angle: Double?, val gust: Double?)

        /** Median of the (up to) three nearest fresh stations. */
        fun parse(data: ByteArray, near: Coordinate, now: Epoch, radiusKm: Double, maxAge: Double): Observation? {
            val stations = parseJson(data)["stations"].arr ?: throw ForecastException("missing stations")
            val all = stations.mapNotNull { s ->
                val temperature = s["temperature"].numOnly ?: return@mapNotNull null
                val t = s["observed"].numOnly ?: return@mapNotNull null
                val lat = s["lat"].numOnly ?: return@mapNotNull null
                val lon = s["lon"].numOnly ?: return@mapNotNull null
                val d = distanceKm(near, Coordinate(lat, lon))
                if (d > max(radiusKm, fillRadiusKm) || now - t >= maxAge) return@mapNotNull null
                Triple(S(temperature, s["humidity"].numOnly, s["city"].str, s["rain_60min"].numOnly,
                    s["wind_strength"].numOnly, s["wind_angle"].numOnly, s["gust_strength"].numOnly), d, t)
            }.sortedBy { it.second }
            val within = all.filter { it.second <= radiusKm }
            if (within.isEmpty()) return null
            val fresh = if (within.size >= 3) within else all.take(3)
            var agreeing = fresh
            if (fresh.size >= 3) {
                val mid = median(fresh.mapNotNull { it.first.temperature })
                if (mid != null) agreeing = fresh.filter { abs((it.first.temperature ?: mid) - mid) <= outlierLimit }
            }
            val nearest = agreeing.take(3)
            val first = nearest.firstOrNull() ?: return null
            val temperature = median(nearest.mapNotNull { it.first.temperature })!!
            val wind = fresh.firstOrNull { it.first.wind != null }?.first
            val name = if (nearest.size == 1) "Netatmo station" else "${nearest.size} Netatmo stations"
            val gauges = within.mapNotNull { it.first.rain }
            return Observation(
                stationName = name + (first.first.city?.let { " in $it" } ?: ""),
                observedAt = nearest.minOf { it.third },
                temperature = (temperature * 10).rnd() / 10,
                humidity = median(nearest.mapNotNull { it.first.humidity }),
                windSpeed = wind?.wind, windDirection = wind?.angle, windGusts = wind?.gust,
                distanceKm = first.second,
                dataProvider = "NETATMO",
                stationTemperatures = agreeing.take(5).mapNotNull { it.first.temperature },
                rainGauges = if (gauges.isEmpty()) null else gauges.size,
                rainLastHourMm = gauges.maxOrNull(),
            )
        }
    }
}

/** Official observations for the sky, with nearby Netatmo stations for temperature and humidity. */
class HyperlocalObservationProvider(
    private val official: ObservationProvider = WorldObservationProvider(),
    private val netatmo: ObservationProvider = NetatmoRelayProvider(),
) : ObservationProvider {
    override suspend fun observation(near: Coordinate): Observation? = coroutineScope {
        val a = async { safely { official.observation(near) } }
        val b = async { safely { netatmo.observation(near) } }
        val base = a.await()
        val local = b.await() ?: return@coroutineScope base
        merge(base, local)
    }

    companion object {
        const val officialLimit = 2.0

        fun merge(base: Observation?, netatmo: Observation): Observation {
            val local = netatmo.copy()
            val temps = (local.stationTemperatures ?: emptyList()).sorted()
            val tightCluster = temps.size >= 3 &&
                (temps.last() - temps.first()) <= 2.5 &&
                (0..temps.size - 3).any { temps[it + 2] - temps[it] <= 1.0 }
            val limit = if (base?.dataProvider == "ON-MTO") {
                if (tightCluster && (base.distanceKm ?: 0.0) > 5.0) 4.5 else 3.0
            } else officialLimit
            if (base != null && (base.distanceKm ?: 0.0) <= 10.0 && abs(base.temperature - local.temperature) > limit &&
                base.observedAt - local.observedAt > -3600) {
                val agreeing = (local.stationTemperatures ?: emptyList()).filter { abs(it - base.temperature) <= limit }
                if (agreeing.isEmpty()) return base
                val v = agreeing.take(3).sorted()
                val mid = if (v.size % 2 == 1) v[v.size / 2] else (v[v.size / 2 - 1] + v[v.size / 2]) / 2
                local.temperature = (mid * 10).rnd() / 10
                local.stationTemperatures = agreeing
                val i = local.stationName.indexOf(" in ")
                val place = if (i >= 0) local.stationName.substring(i) else ""
                local.stationName = (if (v.size == 1) "Netatmo station" else "${v.size} Netatmo stations") + place
            }
            val merged = local.copy(
                condition = base?.condition, conditionText = base?.conditionText,
                skyStationName = base?.stationName, skyDataProvider = base?.dataProvider, skyDistanceKm = base?.distanceKm,
            )
            if (base != null && base.isLocal && base.windSpeed != null) {

                merged.windSpeed = base.windSpeed

                merged.windDirection = base.windDirection ?: merged.windDirection

                merged.windGusts = base.windGusts ?: merged.windGusts

            }
            return merged
        }
    }
}

/** US National Weather Service observations. */
class NWSObservationProvider(private val loader: HttpLoader = defaultLoader) : ObservationProvider {
    override suspend fun observation(near: Coordinate): Observation? {
        if (!Region.inUS(near)) return null
        val c = near.rounded
        val points = parseJson(loader.fetch("https://api.weather.gov/points/${dstr(c.latitude)},${dstr(c.longitude)}", "application/geo+json"))
        val stationsURL = points["properties"]["observationStations"].str ?: return null
        val features = parseJson(loader.fetch(stationsURL, "application/geo+json"))["features"].arr ?: return null
        val stations = features.mapNotNull { f ->
            val g = f["geometry"]["coordinates"].arr ?: return@mapNotNull null
            if (g.size < 2) return@mapNotNull null
            val lat = g[1].numOnly ?: return@mapNotNull null
            val lon = g[0].numOnly ?: return@mapNotNull null
            val d = distanceKm(near, Coordinate(lat, lon))
            val id = f["properties"]["stationIdentifier"].str ?: return@mapNotNull null
            if (d <= 40) Triple(id, f["properties"]["name"].str ?: id, d) else null
        }.sortedBy { it.third }
        for ((id, name, d) in stations.take(3)) {
            val data = safely { loader.fetch("https://api.weather.gov/stations/$id/observations/latest", "application/geo+json") } ?: continue
            val o = safely { parseObservation(data, name, d, nowEpoch()) } ?: continue
            return o
        }
        return null
    }

    companion object {
        fun parseObservation(data: ByteArray, name: String, distance: Double, now: Epoch): Observation? {
            val p = parseJson(data)["properties"]
            val t = p["temperature"]["value"].numOnly ?: return null
            val time = p["timestamp"].str?.let { parseIsoDate(it) } ?: return null
            if (now - time >= 2 * 3600) return null
            var humidity = p["relativeHumidity"]["value"].numOnly
            if (humidity == null) p["dewpoint"]["value"].numOnly?.let { humidity = FeelsLike.relativeHumidity(t, it) }
            val text = p["textDescription"].str
            return Observation(name, time, t, humidity = humidity, windSpeed = p["windSpeed"]["value"].numOnly,
                windDirection = p["windDirection"]["value"].numOnly, condition = WeatherCondition.fromText(text),
                conditionText = if (text.isNullOrEmpty()) null else text, distanceKm = distance, dataProvider = "NWS")
        }
    }
}

/** Germany's DWD via Bright Sky. */
class BrightSkyProvider(private val loader: HttpLoader = defaultLoader) : ObservationProvider {
    override suspend fun observation(near: Coordinate): Observation? {
        if (!Region.inGermany(near)) return null
        val c = near.rounded
        val r = parseJson(loader.fetch("https://api.brightsky.dev/current_weather?lat=${dstr(c.latitude)}&lon=${dstr(c.longitude)}"))
        val w = r["weather"]
        val t = w["temperature"].numOnly ?: return null
        val time = w["timestamp"].str?.let { parseIsoDate(it) } ?: return null
        if (nowEpoch() - time >= 2 * 3600) return null
        val sources = r["sources"].arr
        val sid = w["source_id"].numOnly
        val source = sources?.firstOrNull { it["id"].numOnly == sid } ?: sources?.firstOrNull()
        val condition = when (w["condition"].str) {
            "rain" -> WeatherCondition.rain
            "sleet", "snow", "hail" -> WeatherCondition.snow
            "thunderstorm" -> WeatherCondition.thunderstorm
            "fog" -> WeatherCondition.fog
            else -> when (w["icon"].str) {
                "clear-day", "clear-night" -> WeatherCondition.clear
                "partly-cloudy-day", "partly-cloudy-night" -> WeatherCondition.partlyCloudy
                "cloudy" -> WeatherCondition.overcast
                else -> null
            }
        }
        return Observation(source["station_name"].str ?: "DWD station", time, t, humidity = w["relative_humidity"].numOnly,
            windSpeed = w["wind_speed_10"].numOnly, windDirection = w["wind_direction_10"].numOnly, condition = condition,
            distanceKm = source["distance"].numOnly?.let { it / 1000 }, dataProvider = "DWD")
    }
}

/** Airport METARs worldwide (NOAA Aviation Weather Center). */
class METARProvider(private val loader: HttpLoader = defaultLoader) : ObservationProvider {
    override suspend fun observation(near: Coordinate): Observation? {
        val c = near.rounded
        val d = 0.4
        val bbox = ECCC.bbox(c.latitude - d, c.longitude - d * 1.5, c.latitude + d, c.longitude + d * 1.5)
        val list = parseJson(loader.fetch("https://aviationweather.gov/api/data/metar?bbox=$bbox&format=json")).arr ?: return null
        val best = list.mapNotNull { m ->
            val lat = m["lat"].numOnly ?: return@mapNotNull null
            val lon = m["lon"].numOnly ?: return@mapNotNull null
            m["temp"].numOnly ?: return@mapNotNull null
            val t = m["obsTime"].numOnly ?: return@mapNotNull null
            val dist = distanceKm(near, Coordinate(lat, lon))
            if (dist > 40 || nowEpoch() - t >= 3 * 3600) return@mapNotNull null
            Triple(m, dist, t)
        }.minByOrNull { it.second } ?: return null
        val (m, distance, time) = best
        val temp = m["temp"].numOnly!!
        val name = (m["name"].str ?: m["icaoId"].str ?: "Airport").split(",").first()
        return Observation(name, time, temp, humidity = m["dewp"].numOnly?.let { FeelsLike.relativeHumidity(temp, it) },
            windSpeed = m["wspd"].numOnly?.let { it * 1.852 }, windDirection = m["wdir"].num,
            condition = WeatherCondition.fromMetar(m["wxString"].str, m["cover"].str), distanceKm = distance, dataProvider = "METAR")
    }
}

/** European national weather services served by the relay (MeteoSwiss, GeoSphere, SMHI, FMI, IMGW). */
class RelayOfficialProvider(
    private val baseURL: String = "https://weather-relay.khanofmilton.ca/v1/obs",
    private val loader: HttpLoader = defaultLoader,
) : ObservationProvider {
    override suspend fun observation(near: Coordinate): Observation? {
        if (!Region.inEuropeNational(near)) return null
        val url = buildUrl(baseURL, "lat" to fmt("%.3f", near.latitude), "lon" to fmt("%.3f", near.longitude))
        return parse(loader.fetch(url, timeoutSeconds = 4))
    }

    companion object {
        fun parse(data: ByteArray): Observation? {
            val s = parseJson(data)["station"].obj ?: return null
            val name = s["name"].str ?: return null
            val obs = s["observed"].numOnly ?: return null
            val temp = s["temperature"].numOnly ?: return null
            return Observation(
                stationName = name,
                observedAt = obs,
                temperature = temp,
                humidity = s["humidity"].numOnly,
                windSpeed = s["wind_kmh"].numOnly,
                windDirection = s["wind_dir"].numOnly,
                windGusts = s["gust_kmh"].numOnly,
                distanceKm = s["distance_km"].numOnly,
                dataProvider = s["provider"].str ?: "Europe",
            )
        }
    }
}

/** Picks the right national services for the spot, falling back to the nearest airport anywhere. */
class WorldObservationProvider(
    private val canada: ObservationProvider = CanadaObservationProvider(),
    private val us: ObservationProvider = NWSObservationProvider(),
    private val germany: ObservationProvider = BrightSkyProvider(),
    private val europeNational: ObservationProvider = RelayOfficialProvider(),
    private val airports: ObservationProvider = METARProvider(),
) : ObservationProvider {
    override suspend fun observation(near: Coordinate): Observation? = coroutineScope {
        if (Region.inCanada(near)) safely { canada.observation(near) }?.let { return@coroutineScope it }
        val a = async { safely { us.observation(near) } }
        val b = async { safely { germany.observation(near) } }
        val c = async { safely { europeNational.observation(near) } }
        val d = async { safely { airports.observation(near) } }
        val sky = d.await()
        val best = listOfNotNull(a.await(), b.await(), c.await(), sky).minByOrNull { it.distanceKm ?: Double.POSITIVE_INFINITY }
            ?: return@coroutineScope null
        if (best.condition == null && sky?.condition != null) {
            best.copy(
                condition = sky.condition,
                conditionText = sky.conditionText,
                skyStationName = sky.stationName,
                skyDataProvider = sky.dataProvider,
                skyDistanceKm = sky.distanceKm,
            )
        } else best
    }
}

object ObservationSource {
    /** On unless turned off, in the app and the widget alike. */
    const val hyperlocalDefault = true

    fun provider(hyperlocal: Boolean): ObservationProvider =
        if (hyperlocal) HyperlocalObservationProvider() else WorldObservationProvider()
}
