package com.khanweather.core

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Global forecasts from Open-Meteo (https://open-meteo.com). Free for non-commercial use, no key.
 * Data licensed CC BY 4.0, so the UI shows `attribution`.
 */
class OpenMeteoProvider(
    private val baseURL: String = "https://api.open-meteo.com/v1/forecast",
    private val forecastDays: Int = 10,
    private val loader: HttpLoader = defaultLoader,
) {
    val name = "Open-Meteo"
    val attribution = "Weather data by Open-Meteo.com (CC BY 4.0)"

    /**
     * `anchor` gives the local station temperature that re-weights the first hours of the blend.
     * It is awaited only once the model data has arrived.
     */
    suspend fun forecast(coordinate: Coordinate, anchor: suspend () -> ModelBlend.Anchor? = { null }): Forecast = coroutineScope {
        val blended = if (usesBlend(coordinate)) async { blendedTemperatures(coordinate, anchor) } else null
        val data = loader.fetch(url(coordinate), timeoutSeconds = 20)
        val forecast = parse(data, nowEpoch())
        val temps = blended?.await() ?: return@coroutineScope forecast
        forecast.applying(temps)
    }

    /**
     * Blended hourly temperatures; null if the request fails, so the default stays. If the
     * region's own models are refused, it tries again with the worldwide models and weights.
     */
    suspend fun blendedTemperatures(coordinate: Coordinate, anchor: suspend () -> ModelBlend.Anchor? = { null }): ModelTemperatures? {
        val region = BlendRegion.at(coordinate)
        val tries = if (region == BlendRegion.fallback) listOf(region) else listOf(region, BlendRegion.fallback)
        for (r in tries) {
            val data = try { loader.fetch(blendURL(coordinate, r)) } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                if (e is HttpStatusException) continue
                return null
            }
            val observed = anchor()
            return try { parseBlend(data, r, observed, nowEpoch()) } catch (e: Exception) { null }
        }
        return null
    }

    fun blendURL(coordinate: Coordinate, region: BlendRegion = BlendRegion.at(coordinate)): String {
        val c = coordinate.rounded
        return buildUrl(baseURL,
            "latitude" to dstr(c.latitude), "longitude" to dstr(c.longitude),
            "hourly" to "temperature_2m,apparent_temperature,precipitation,snowfall",
            "models" to region.models.joinToString(",") { it.raw },
            "timezone" to "auto", "timeformat" to "unixtime", "forecast_days" to forecastDays.toString())
    }

    fun url(coordinate: Coordinate): String {
        val c = coordinate.rounded
        return buildUrl(baseURL,
            "latitude" to dstr(c.latitude), "longitude" to dstr(c.longitude),
            "current" to currentFields.joinToString(","),
            "hourly" to hourlyFields.joinToString(","),
            "daily" to dailyFields.joinToString(","),
            "minutely_15" to minutelyFields.joinToString(","),
            "forecast_minutely_15" to "12",
            "timezone" to "auto", "timeformat" to "unixtime",
            "forecast_days" to forecastDays.toString(),
            "past_days" to "1")
    }

    /** Blended temperatures keyed by hour (unix seconds), to lay over the default forecast. */
    class ModelTemperatures {
        class Hour(
            val temperature: Double,
            val feelsLike: Double?,
            val low: Double,
            val high: Double,
            val count: Int,
            val wet: Int,
            val freezing: Int,
            val precipitation: Map<WeatherModel, Double> = emptyMap(),
            val type: PrecipitationKind? = null,
        )

        val hourly = mutableMapOf<Long, Hour>()
    }

    companion object {
        /** North America, where the high-resolution Canadian and US models cover the spot. */
        /** Whether the spot's region uses the blend (it scored better than best match there). */
        fun usesBlend(c: Coordinate): Boolean = BlendRegion.at(c).useBlend

        val currentFields = listOf(
            "temperature_2m", "apparent_temperature", "relative_humidity_2m", "is_day",
            "precipitation", "weather_code", "wind_speed_10m", "wind_direction_10m",
            "pressure_msl", "wind_gusts_10m",
        )
        val hourlyFields = listOf(
            "temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation",
            "weather_code", "is_day", "relative_humidity_2m", "dew_point_2m", "wind_speed_10m",
            "wind_gusts_10m", "wind_direction_10m", "uv_index", "rain", "showers", "snowfall", "visibility",
            "pressure_msl",
        )
        val dailyFields = listOf(
            "weather_code", "temperature_2m_max", "temperature_2m_min",
            "apparent_temperature_max", "apparent_temperature_min", "precipitation_probability_max",
            "rain_sum", "showers_sum", "snowfall_sum", "sunrise", "sunset", "uv_index_max",
            "wind_speed_10m_max", "wind_gusts_10m_max", "wind_direction_10m_dominant", "precipitation_hours",
        )
        val minutelyFields = listOf("precipitation", "rain", "snowfall")

        /** Each series' value at `epoch`, interpolated between the two hours around it. */
        fun valuesAt(epoch: Double, times: List<Double>, series: Map<WeatherModel, List<Double?>>): Map<WeatherModel, Double> {
            if (times.isEmpty()) return emptyMap()
            val idx = times.indexOfFirst { it >= epoch }
            val after = if (idx >= 0) idx else times.size - 1
            val before = max(0, if (times[after] > epoch) after - 1 else after)
            val span = times[after] - times[before]
            val f = if (span > 0) min(1.0, max(0.0, (epoch - times[before]) / span)) else 0.0
            val out = mutableMapOf<WeatherModel, Double>()
            for ((m, s) in series) {
                val a = s.at(before)
                val b = s.at(after)
                if (after >= s.size || a == null || b == null) {
                    if (before < s.size) s[before]?.let { out[m] = it }
                } else {
                    out[m] = a + (b - a) * f
                }
            }
            return out
        }

        /** With several models, Open-Meteo suffixes each field: "temperature_2m_gem_seamless". */
        fun parseBlend(data: ByteArray, region: BlendRegion = BlendRegion.home, anchor: ModelBlend.Anchor? = null, now: Epoch): ModelTemperatures {
            val root = parseJson(data)
            val hourly = root["hourly"].obj ?: throw ForecastException("The weather service response was missing hourly.")
            val times = hourly["time"].arr?.map { it.numOnly ?: 0.0 } ?: throw ForecastException("missing hourly")
            fun series(field: String) = region.models.associateWith { hourly["${field}_${it.raw}"].doubles() }
            val temps = series("temperature_2m")
            val feels = series("apparent_temperature")
            val precip = series("precipitation")
            val snow = series("snowfall")

            val observedTemperature = anchor?.temperature
            val currentModelTemps = anchor?.let { valuesAt(it.time, times, temps) }

            val out = ModelTemperatures()
            for ((i, t) in times.withIndex()) {
                val lead = (t - now) / 3600
                fun at(s: Map<WeatherModel, List<Double?>>): Map<WeatherModel, Double> {
                    val m = mutableMapOf<WeatherModel, Double>()
                    for ((k, v) in s) v.at(i)?.let { m[k] = it }
                    return m
                }
                val hourTemps = at(temps)
                val temp = ModelBlend.blend(hourTemps, lead, region, observedTemperature, currentModelTemps) ?: continue
                val values = hourTemps.values.toList()
                val hourPrecip = at(precip).filterKeys { hourTemps.containsKey(it) }
                val wet = hourPrecip.count { it.value >= ModelBlend.wetHourMm }
                out.hourly[t.toLong()] = ModelTemperatures.Hour(
                    temperature = temp,
                    feelsLike = ModelBlend.blend(at(feels), lead, region, observedTemperature, currentModelTemps),
                    low = values.min(), high = values.max(), count = values.size,
                    wet = wet, freezing = values.count { it <= 0 },
                    precipitation = hourPrecip,
                    type = ModelBlend.precipitationType(temp, hourPrecip, at(snow).filterKeys { hourTemps.containsKey(it) }),
                )
            }
            return out
        }

        /** Adds two optional amounts; null only when both are missing. */
        fun sum(a: Double?, b: Double?): Double? = if (a == null && b == null) null else (a ?: 0.0) + (b ?: 0.0)

        fun parse(data: ByteArray, fetchedAt: Epoch): Forecast {
            val r = parseJson(data)
            val cur = r["current"].obj ?: throw ForecastException("The weather service response was missing current.")
            val temperature = cur["temperature_2m"].numOnly
                ?: throw ForecastException("The weather service response was missing current temperature.")
            val current = CurrentConditions(
                time = cur["time"].numOnly ?: 0.0,
                temperature = temperature,
                feelsLike = cur["apparent_temperature"].numOnly ?: temperature,
                feelsLikeKind = FeelsLikeKind.apparent,
                humidity = cur["relative_humidity_2m"].numOnly,
                windSpeed = cur["wind_speed_10m"].numOnly,
                windDirection = cur["wind_direction_10m"].numOnly,
                precipitation = cur["precipitation"].numOnly,
                condition = WeatherCondition.fromWmo(cur["weather_code"].numOnly?.toInt()),
                isDay = (cur["is_day"].numOnly?.toInt() ?: 1) == 1,
                pressure = cur["pressure_msl"].numOnly,
                windGusts = cur["wind_gusts_10m"].numOnly,
            )

            var hourly = mutableListOf<HourlyForecast>()
            r["hourly"].obj?.let { h ->
                val time = h["time"].doubles()
                fun f(k: String) = h[k].doubles()
                val temp = f("temperature_2m"); val app = f("apparent_temperature"); val pp = f("precipitation_probability")
                val pr = f("precipitation"); val code = f("weather_code"); val day = f("is_day"); val rh = f("relative_humidity_2m")
                val dew = f("dew_point_2m"); val ws = f("wind_speed_10m"); val wg = f("wind_gusts_10m"); val wd = f("wind_direction_10m")
                val uv = f("uv_index"); val rain = f("rain"); val showers = f("showers"); val snow = f("snowfall")
                val vis = f("visibility"); val press = f("pressure_msl")
                for ((i, t) in time.withIndex()) {
                    val tt = temp.at(i) ?: continue
                    hourly.add(HourlyForecast(
                        time = t ?: continue,
                        temperature = tt,
                        feelsLike = app.at(i),
                        precipitationProbability = pp.at(i),
                        precipitation = pr.at(i),
                        condition = WeatherCondition.fromWmo(code.at(i)?.toInt()).ignoringTrace(pp.at(i), pr.at(i)),
                        isDay = (day.at(i)?.toInt() ?: 1) == 1,
                        humidity = rh.at(i), dewPoint = dew.at(i), windSpeed = ws.at(i), windGusts = wg.at(i),
                        windDirection = wd.at(i), uvIndex = uv.at(i), rain = sum(rain.at(i), showers.at(i)),
                        snowfall = snow.at(i), visibility = vis.at(i), pressure = press.at(i),
                    ))
                }
            }

            var daily = mutableListOf<DailyForecast>()
            r["daily"].obj?.let { d ->
                val time = d["time"].doubles()
                fun f(k: String) = d[k].doubles()
                val code = f("weather_code"); val hi = f("temperature_2m_max"); val lo = f("temperature_2m_min")
                val ahi = f("apparent_temperature_max"); val alo = f("apparent_temperature_min")
                val pp = f("precipitation_probability_max"); val rs = f("rain_sum"); val ss = f("showers_sum")
                val sn = f("snowfall_sum"); val rise = f("sunrise"); val set = f("sunset"); val uv = f("uv_index_max")
                val ws = f("wind_speed_10m_max"); val wg = f("wind_gusts_10m_max"); val wd = f("wind_direction_10m_dominant")
                val ph = f("precipitation_hours")
                for ((i, t) in time.withIndex()) {
                    val high = hi.at(i) ?: continue
                    val low = lo.at(i) ?: continue
                    val rain = sum(rs.at(i), ss.at(i))
                    val snow = sn.at(i)
                    val total = if (rain == null && snow == null) null else (rain ?: 0.0) + (snow ?: 0.0)
                    daily.add(DailyForecast(
                        date = t ?: continue, high = high, low = low,
                        feelsLikeHigh = ahi.at(i), feelsLikeLow = alo.at(i),
                        precipitationProbability = pp.at(i),
                        condition = WeatherCondition.fromWmo(code.at(i)?.toInt()).ignoringTrace(pp.at(i), total),
                        rainSum = rain, snowfallSum = snow,
                        sunrise = rise.at(i), sunset = set.at(i), uvIndexMax = uv.at(i),
                        windSpeedMax = ws.at(i), windGustsMax = wg.at(i), windDirectionDominant = wd.at(i),
                        precipitationHours = ph.at(i),
                    ))
                }
            }

            val minutely = mutableListOf<PrecipitationSlot>()
            r["minutely_15"].obj?.let { m ->
                val time = m["time"].doubles()
                val p = m["precipitation"].doubles(); val rain = m["rain"].doubles(); val snow = m["snowfall"].doubles()
                for ((i, t) in time.withIndex()) {
                    val pv = p.at(i) ?: continue
                    minutely.add(PrecipitationSlot(t ?: continue, pv, rain.at(i) ?: 0.0, snow.at(i) ?: 0.0))
                }
            }

            // `past_days=1` adds yesterday; keep yesterday's hours apart and drop yesterday's row.
            val tzId = r["timezone"].str ?: java.time.ZoneId.systemDefault().id
            val cal = Cal(tzId)
            val startOfToday = cal.startOfDay(current.time)
            var recentHours: List<HourlyForecast>? = null
            if (hourly.any { it.time < startOfToday }) {
                val startOfTomorrow = cal.addingDays(startOfToday, 1)
                recentHours = hourly.filter { it.time < startOfTomorrow }.map { it.copy() }
                hourly = hourly.filter { it.time >= startOfToday }.toMutableList()
            }
            daily = daily.filter { it.date > startOfToday - 3600 }.toMutableList()

            val forecast = Forecast(
                location = Coordinate(r["latitude"].numOnly ?: 0.0, r["longitude"].numOnly ?: 0.0),
                timeZoneIdentifier = tzId,
                current = current,
                hourly = hourly,
                daily = daily,
                source = "Open-Meteo",
                fetchedAt = fetchedAt,
                minutely = minutely,
                recentHours = recentHours,
            )
            return forecast.withDailyHeadlines().withStandardFeelsLike()
        }
    }
}

/**
 * Swaps in blended temperatures wherever they cover an hour, then recomputes each fully
 * covered day's high and low from those hours.
 */
fun Forecast.applying(temps: OpenMeteoProvider.ModelTemperatures): Forecast {
    val copy = deepCopy()
    copy.hourly = hourly.map { hour ->
        val h = hour.copy()
        temps.hourly[hour.time.toLong()]?.let { t ->
            h.temperature = t.temperature
            h.feelsLike = t.feelsLike ?: h.feelsLike
            h.modelLow = t.low
            h.modelHigh = t.high
            h.modelCount = t.count
            h.modelsWet = t.wet
            h.modelsFreezing = t.freezing
            h.precipitationProbability = ModelBlend.hourlyChance(h.precipitationProbability, t.wet, t.count)
            t.type?.let { h.setPrecipitationType(it) }
        }
        h
    }
    copy.daily = daily.mapIndexed { index, day ->
        val d = day.copy()
        val dayHours = copy.hoursOn(day)
        val hours = dayHours.filter { temps.hourly.containsKey(it.time.toLong()) }
        if (hours.size >= 20) {
            val totals = mutableMapOf<WeatherModel, Double>()
            val counts = mutableMapOf<WeatherModel, Int>()
            for (h in hours) {
                for ((m, mm) in temps.hourly[h.time.toLong()]?.precipitation ?: emptyMap()) {
                    totals[m] = (totals[m] ?: 0.0) + mm
                    counts[m] = (counts[m] ?: 0) + 1
                }
            }
            val full = totals.filter { counts[it.key] == hours.size }
            d.precipitationProbability = ModelBlend.dailyChance(d.precipitationProbability,
                full.values.count { it >= ModelBlend.wetDayMm }, full.size, index)
        }
        if (hours.size == dayHours.size && hours.size >= 20) {
            d.rainSum = hours.fold(0.0) { a, h -> a + (h.rain ?: 0.0) }
            d.snowfallSum = hours.fold(0.0) { a, h -> a + (h.snowfall ?: 0.0) }
        }
        val spreads = hours.mapNotNull { h -> val hi = h.modelHigh; val lo = h.modelLow; if (hi != null && lo != null) hi - lo else null }
        if (spreads.isNotEmpty()) d.modelSpread = spreads.sum() / spreads.size
        if (hours.size < 18) return@mapIndexed d
        d.high = hours.maxOf { it.temperature } + ModelBlend.highAllowance
        d.low = hours.minOf { it.temperature } - ModelBlend.lowAllowance
        val feels = hours.mapNotNull { it.feelsLike }
        if (feels.size == hours.size) {
            d.feelsLikeHigh = feels.max()
            d.feelsLikeLow = feels.min()
        }
        d
    }
    // "Now" from the same blend as the hourly curve, read at the minute of the current conditions.
    blendedTemperature(temps, current.time)?.let { copy.current.temperature = it }
    val hourStart = (floor(current.time / 3600) * 3600).toLong()
    temps.hourly[hourStart]?.type?.let { copy.current.condition = copy.current.condition.converted(it) }
    copy.extremesIncludePeak = true
    return copy.withDailyHeadlines().withStandardFeelsLike()
}

/** The blended temperature at `time`, read between the two hours around it. */
fun blendedTemperature(temps: OpenMeteoProvider.ModelTemperatures, time: Epoch): Double? {
    val start = (floor(time / 3600) * 3600).toLong()
    val a = temps.hourly[start]?.temperature ?: return null
    val f = (time - start) / 3600
    if (f <= 0) return a
    val b = temps.hourly[start + 3600]?.temperature ?: return null
    return a + (b - a) * f
}
