@file:Suppress("EnumEntryName")

package com.khanweather.core

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable

/** Air quality and pollen at one spot (Open-Meteo CAMS, plus ECCC AQHI in Canada). */
@Serializable
data class AirQuality(
    val time: Epoch,
    val usAQI: Double? = null,
    val todayMaxAQI: Double? = null,
    val pm25: Double? = null,
    val pm10: Double? = null,
    val ozone: Double? = null,
    val nitrogenDioxide: Double? = null,
    val pollen: List<Pollen> = emptyList(),
    val hasPollenData: Boolean = false,
    var aqhi: Double? = null,
    var aqhiStation: String? = null,
    var aqhiTodayMax: Double? = null,
) {
    val category: AQICategory? get() = usAQI?.let { AQICategory.of(it) }

    val aqhiCategory: AQICategory?
        get() {
            val a = aqhi ?: return null
            return when {
                a < 3.5 -> AQICategory.good
                a < 6.5 -> AQICategory.moderate
                a < 10.5 -> AQICategory.unhealthy
                else -> AQICategory.veryUnhealthy
            }
        }

    val aqhiRiskLabel: String?
        get() {
            val a = aqhi ?: return null
            return when {
                a < 3.5 -> "Low risk"
                a < 6.5 -> "Moderate risk"
                a < 10.5 -> "High risk"
                else -> "Very high risk"
            }
        }
}

enum class AQICategory(val label: String, val advice: String) {
    good("Good", "Ideal air quality for outdoor activities. Enjoy your usual outdoor activities."),
    moderate("Moderate", "No need to modify your usual outdoor activities unless you experience symptoms such as coughing and throat irritation."),
    sensitive("Unhealthy for sensitive groups", "Consider reducing or rescheduling strenuous activities outdoors if you are experiencing symptoms."),
    unhealthy("Unhealthy", "Reduce or reschedule strenuous activities outdoors. Children and the elderly should also take it easy."),
    veryUnhealthy("Very unhealthy", "Avoid strenuous activities outdoors. Children and the elderly should also avoid outdoor physical exertion."),
    hazardous("Hazardous", "Avoid strenuous activities outdoors. Children and the elderly should also avoid outdoor physical exertion.");

    companion object {
        fun of(aqi: Double): AQICategory = when {
            aqi < 50.5 -> good
            aqi < 100.5 -> moderate
            aqi < 150.5 -> sensitive
            aqi < 200.5 -> unhealthy
            aqi < 300.5 -> veryUnhealthy
            else -> hazardous
        }
    }
}

@Serializable
data class Pollen(val kind: Kind, val grains: Double) {
    @Serializable
    enum class Kind { alder, birch, grass, mugwort, olive, ragweed;
        val label: String get() = name.replaceFirstChar { it.uppercase() }
    }

    enum class Level(val label: String) { low("Low"), moderate("Moderate"), high("High"), veryHigh("Very high") }

    /** US National Allergy Bureau bands, which differ for trees, grass and weeds. */
    val level: Level
        get() {
            val (moderate, high, veryHigh) = when (kind) {
                Kind.alder, Kind.birch, Kind.olive -> Triple(15.0, 90.0, 1500.0)
                Kind.grass -> Triple(5.0, 20.0, 200.0)
                Kind.mugwort, Kind.ragweed -> Triple(10.0, 50.0, 500.0)
            }
            return when {
                grains >= veryHigh -> Level.veryHigh
                grains >= high -> Level.high
                grains >= moderate -> Level.moderate
                else -> Level.low
            }
        }
}

class AirQualityProvider(
    private val baseURL: String = "https://air-quality-api.open-meteo.com/v1/air-quality",
    private val loader: HttpLoader = defaultLoader,
) {
    fun url(coordinate: Coordinate): String {
        val c = coordinate.rounded
        val pollen = Pollen.Kind.entries.map { "${it.name}_pollen" }
        return buildUrl(baseURL, "latitude" to dstr(c.latitude), "longitude" to dstr(c.longitude),
            "current" to (listOf("us_aqi", "pm2_5", "pm10", "ozone", "nitrogen_dioxide") + pollen).joinToString(","),
            "hourly" to "us_aqi", "forecast_days" to "1", "timezone" to "auto", "timeformat" to "unixtime")
    }

    suspend fun airQuality(c: Coordinate, zoneId: String = java.time.ZoneId.systemDefault().id): AirQuality = coroutineScope {
        val om = async { loader.fetch(url(c)) }
        val inCanada = Region.inCanada(c)
        val obs = async { if (inCanada) safely { parseAQHI(loader.fetch(aqhiURL("aqhi-observations-realtime", c, 30)), c) } else null }
        val fc = async { if (inCanada) safely { parseAQHIForecast(loader.fetch(aqhiURL("aqhi-forecasts-realtime", c, 300)), c, nowEpoch(), zoneId) } else null }
        val aq = parse(om.await())
        obs.await()?.let { aq.aqhi = it.first; aq.aqhiStation = it.second }
        aq.aqhiTodayMax = fc.await()
        aq
    }

    private fun aqhiURL(collection: String, c: Coordinate, limit: Int): String {
        val span = 0.45
        return buildUrl("https://api.weather.gc.ca/collections/$collection/items", "f" to "json",
            "bbox" to ECCC.bbox(c.longitude - span * 1.4, c.latitude - span, c.longitude + span * 1.4, c.latitude + span),
            "latest" to "true", "limit" to limit.toString())
    }

    companion object {
        fun parseAQHIForecast(data: ByteArray, near: Coordinate, now: Epoch, zoneId: String): Double? {
            val features = parseJson(data)["features"].arr ?: return null
            val cal = Cal(zoneId)
            val midnight = cal.addingDays(cal.startOfDay(now), 1)
            var bestDist = Double.POSITIVE_INFINITY
            var bestID: String? = null
            val byStation = mutableMapOf<String, MutableList<Double>>()
            for (f in features) {
                val p = f["properties"]
                val v = p["aqhi"].numOnly ?: continue
                val point = ECCC.pointCoordinate(f["geometry"]) ?: continue
                val sid = p["location_id"].str ?: p["location_name_en"].str ?: "station"
                val d = distanceKm(near, point)
                if (d < bestDist) { bestDist = d; bestID = sid }
                val at = p["forecast_datetime"].str?.let { parseIsoDate(it) }
                if (at != null && !(at < midnight && at > now - 3600)) continue
                byStation.getOrPut(sid) { mutableListOf() }.add(v)
            }
            return bestID?.let { byStation[it]?.maxOrNull() }
        }

        fun parseAQHI(data: ByteArray, near: Coordinate): Pair<Double, String>? {
            val features = parseJson(data)["features"].arr ?: return null
            var best: Triple<Double, Double, String>? = null
            for (f in features) {
                val v = f["properties"]["aqhi"].numOnly ?: continue
                val point = ECCC.pointCoordinate(f["geometry"]) ?: continue
                val d = distanceKm(near, point)
                if (d >= (best?.first ?: Double.POSITIVE_INFINITY)) continue
                best = Triple(d, v, f["properties"]["location_name_en"].str ?: "Nearby station")
            }
            return best?.let { it.second to it.third }
        }

        fun parse(data: ByteArray): AirQuality {
            val r = parseJson(data)
            val cur = r["current"]
            fun v(k: String) = cur[k].numOnly
            val time = v("time") ?: nowEpoch()
            var hasPollen = false
            val pollen = mutableListOf<Pollen>()
            for (kind in Pollen.Kind.entries) {
                val grains = v("${kind.name}_pollen") ?: continue
                hasPollen = true
                if (grains >= 1) pollen.add(Pollen(kind, grains))
            }
            pollen.sortByDescending { it.grains }
            val h = r["hourly"]
            val times = h["time"].doubles()
            val aqi = h["us_aqi"].doubles()
            val todayMax = if (h == null || h["us_aqi"] == null) null
            else times.zip(aqi).filter { (t, _) -> (t ?: 0.0) + 3600 > time }.mapNotNull { it.second }.maxOrNull()
            return AirQuality(time, v("us_aqi"), todayMax, v("pm2_5"), v("pm10"), v("ozone"), v("nitrogen_dioxide"),
                pollen, hasPollen)
        }
    }
}

/** A place the user saved, such as work or family. */
@Serializable
data class SavedPlace(
    val id: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    /** Region and country, e.g. "Ontario, Canada". */
    val detail: String? = null,
    val coordinate: Coordinate,
)

/** Place search by name with Open-Meteo's free geocoding API. */
class PlaceSearch(private val loader: HttpLoader = defaultLoader) {
    suspend fun search(query: String): List<SavedPlace> {
        val q = query.trim()
        if (q.length < 2) return emptyList()
        val data = loader.fetch(buildUrl("https://geocoding-api.open-meteo.com/v1/search",
            "name" to q, "count" to "10", "language" to "en", "format" to "json"))
        return (parseJson(data)["results"].arr ?: return emptyList()).mapNotNull { r ->
            val name = r["name"].str ?: return@mapNotNull null
            val lat = r["latitude"].numOnly ?: return@mapNotNull null
            val lon = r["longitude"].numOnly ?: return@mapNotNull null
            val detail = listOfNotNull(r["admin1"].str, r["country"].str).filter { it.isNotEmpty() && it != name }
            SavedPlace(name = name, detail = detail.joinToString(", ").ifEmpty { null }, coordinate = Coordinate(lat, lon))
        }
    }
}

data class ModelDay(
    val model: WeatherModel,
    val date: Epoch,
    val high: Double?,
    val low: Double?,
    val condition: WeatherCondition,
    val rainMm: Double?,
    val snowCm: Double?,
)

/** The same days from several weather models, side by side. */
class ModelComparisonProvider(private val loader: HttpLoader = defaultLoader) {
    private val core = listOf(WeatherModel.bestMatch, WeatherModel.canada, WeatherModel.us, WeatherModel.europe, WeatherModel.germany)

    suspend fun days(coordinate: Coordinate, forecastDays: Int = 10): List<ModelDay> = try {
        days(coordinate, WeatherModel.requested(coordinate), forecastDays)
    } catch (e: Exception) {
        if (e is kotlinx.coroutines.CancellationException) throw e
        days(coordinate, core, forecastDays)
    }

    private suspend fun days(coordinate: Coordinate, models: List<WeatherModel>, forecastDays: Int): List<ModelDay> {
        val c = coordinate.rounded
        val url = buildUrl("https://api.open-meteo.com/v1/forecast", "latitude" to dstr(c.latitude), "longitude" to dstr(c.longitude),
            "daily" to "weather_code,temperature_2m_max,temperature_2m_min,rain_sum,showers_sum,snowfall_sum",
            "models" to models.joinToString(",") { it.raw }, "timezone" to "auto", "timeformat" to "unixtime",
            "forecast_days" to forecastDays.toString())
        return parse(loader.fetch(url), models, BlendRegion.at(coordinate))
    }

    companion object {
        fun parse(data: ByteArray, models: List<WeatherModel> = WeatherModel.requested, region: BlendRegion = BlendRegion.home): List<ModelDay> {
            val daily = parseJson(data)["daily"].obj ?: throw ForecastException("missing daily")
            val times = daily["time"].doubles()
            fun series(field: String, m: WeatherModel) = (daily["${field}_${m.raw}"] ?: daily[field]).doubles()
            val out = mutableListOf<ModelDay>()
            for (model in models) {
                val hi = series("temperature_2m_max", model); val lo = series("temperature_2m_min", model)
                val code = series("weather_code", model); val rain = series("rain_sum", model)
                val showers = series("showers_sum", model); val snow = series("snowfall_sum", model)
                for ((i, t) in times.withIndex()) {
                    if (hi.at(i) == null && lo.at(i) == null) continue
                    out.add(ModelDay(model, t ?: continue, hi.at(i), lo.at(i), WeatherCondition.fromWmo(code.at(i)?.toInt()),
                        OpenMeteoProvider.sum(rain.at(i), showers.at(i)), snow.at(i)))
                }
            }
            return out + blendRows(out, region)
        }

        /** The Khan Weather row shows the app's own displayed high and low for each day. */
        fun showingApp(rows: List<ModelDay>, appDays: List<DailyForecast>, used: WeatherModel, zoneId: String): List<ModelDay> {
            val cal = Cal(zoneId)
            return rows.map { row ->
                if (row.model != used) return@map row
                val day = appDays.firstOrNull { cal.isSameDay(it.date, row.date) } ?: return@map row
                row.copy(high = day.high, low = day.low)
            }
        }

        fun blendRows(days: List<ModelDay>, region: BlendRegion = BlendRegion.home): List<ModelDay> {
            val dates = days.map { it.date }.toSet().sorted()
            return dates.mapIndexedNotNull { index, date ->
                val sameDay = days.filter { it.date == date && it.model in region.models }
                val lead = index * 24.0 + 12
                fun blend(value: (ModelDay) -> Double?): Double? {
                    val m = linkedMapOf<WeatherModel, Double>()
                    for (d in sameDay) value(d)?.let { if (!m.containsKey(d.model)) m[d.model] = it }
                    return ModelBlend.blend(m, lead, region)
                }
                val high = blend { it.high } ?: return@mapIndexedNotNull null
                val low = blend { it.low } ?: return@mapIndexedNotNull null
                val condition = days.firstOrNull { it.date == date && it.model == WeatherModel.bestMatch }?.condition
                    ?: sameDay.firstOrNull()?.condition ?: WeatherCondition.unknown
                ModelDay(WeatherModel.blend, date, high, low, condition, blend { it.rainMm }, blend { it.snowCm })
            }
        }
    }
}
