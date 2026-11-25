package com.khanweather.core

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** A point on Earth. Rounded to 4 decimals (about 11 m) before it is sent to any provider. */
@Serializable
data class Coordinate(val latitude: Double, val longitude: Double) {
    val rounded: Coordinate
        get() = Coordinate((latitude * 10_000).rnd() / 10_000, (longitude * 10_000).rnd() / 10_000)

    companion object {
        /** Used when location access is denied or not yet available. */
        val fallback = Coordinate(43.6532, -79.3832) // Toronto
    }
}

@Serializable
data class CurrentConditions(
    var time: Epoch,
    var temperature: Double,
    var feelsLike: Double,
    var feelsLikeKind: FeelsLikeKind,
    var humidity: Double? = null,
    var windSpeed: Double? = null,      // km/h
    var windDirection: Double? = null,  // degrees
    var precipitation: Double? = null,  // mm
    var condition: WeatherCondition,
    var isDay: Boolean,
    /** Sea-level pressure, hPa. */
    var pressure: Double? = null,
    var windGusts: Double? = null,      // km/h
)

@Serializable
data class HourlyForecast(
    var time: Epoch,
    var temperature: Double,
    var feelsLike: Double? = null,
    var precipitationProbability: Double? = null,
    /** Precipitation in the hour, mm. */
    var precipitation: Double? = null,
    var condition: WeatherCondition,
    /** False between sunset and sunrise, so clear hours show a moon instead of a sun. */
    var isDay: Boolean = true,
    var humidity: Double? = null,
    var dewPoint: Double? = null,
    var windSpeed: Double? = null,
    var windGusts: Double? = null,
    var windDirection: Double? = null,
    var uvIndex: Double? = null,
    /** mm */
    var rain: Double? = null,
    /** cm */
    var snowfall: Double? = null,
    /** metres */
    var visibility: Double? = null,
    var pressure: Double? = null,
    /** Coldest and warmest model temperature, °C (North America only). */
    var modelLow: Double? = null,
    var modelHigh: Double? = null,
    var modelCount: Int? = null,
    var modelsWet: Int? = null,
    var modelsFreezing: Int? = null,
) {
    /** What a precipitation chance for this hour would be. */
    val precipitationKind: PrecipitationKind
        get() = PrecipitationKind.guess(rain, snowfall, condition, temperature, temperature)

    /** True when both rain and snow are expected in meaningful amounts this hour. */
    val isMixedPrecipitation: Boolean
        get() = condition.isPrecipitation && (rain ?: 0.0) >= 0.2 && (snowfall ?: 0.0) >= 0.2

    /**
     * Makes this hour's rain and snow match `type`: pure rain/snow moves all water to one side;
     * `mixed` splits water between rain (mm) and snow (cm) by `snowShare`. Freezing rain is left alone.
     */
    fun setPrecipitationType(type: PrecipitationKind, snowShare: Double? = null) {
        if (condition == WeatherCondition.freezingRain || condition == WeatherCondition.freezingDrizzle) return
        val water = max(precipitation ?: 0.0, (rain ?: 0.0) + (snowfall ?: 0.0) * 0.7)
        if (type == PrecipitationKind.mixed) {
            val share = min(0.8, max(0.2, snowShare ?: 0.5))
            condition = condition.converted(if (share >= 0.5) PrecipitationKind.snow else PrecipitationKind.rain)
            if (water <= 0) return
            snowfall = (water * share) / 0.7
            rain = water * (1.0 - share)
            return
        }
        condition = condition.converted(type)
        if (water <= 0) return
        if (type == PrecipitationKind.snow) {
            snowfall = water / 0.7; rain = 0.0
        } else {
            rain = water; snowfall = 0.0
        }
    }
}

@Serializable
data class DailyForecast(
    var date: Epoch,
    var high: Double,
    var low: Double,
    var feelsLikeHigh: Double? = null,
    var feelsLikeLow: Double? = null,
    var precipitationProbability: Double? = null,
    var condition: WeatherCondition,
    /** Total rain and showers for the day, in mm. */
    var rainSum: Double? = null,
    /** Total snowfall for the day, in cm. */
    var snowfallSum: Double? = null,
    /** "Rain then snow" and the like. */
    var summary: String? = null,
    var sunrise: Epoch? = null,
    var sunset: Epoch? = null,
    var uvIndexMax: Double? = null,
    var windSpeedMax: Double? = null,
    var windGustsMax: Double? = null,
    var windDirectionDominant: Double? = null,
    var precipitationHours: Double? = null,
    /** How far apart the blended models are over the day, on average, °C. */
    var modelSpread: Double? = null,
) {
    /** Sure when the models are within about 2°, unsure past about 4°. */
    val confidence: ForecastConfidence?
        get() {
            val s = modelSpread ?: return null
            if (s <= 2.5) return ForecastConfidence.sure
            if (s <= 4.5) return ForecastConfidence.fair
            return ForecastConfidence.unsure
        }

    val precipitationKind: PrecipitationKind
        get() = PrecipitationKind.guess(rainSum, snowfallSum, condition, low, high)

    /** True when the day brings both rain and snow. */
    val isMixedPrecipitation: Boolean
        get() = condition.isPrecipitation && (((rainSum ?: 0.0) >= 0.2 && (snowfallSum ?: 0.0) >= 0.2) || summary != null)
}

/** Fifteen minutes of precipitation from the short-range forecast. */
@Serializable
data class PrecipitationSlot(
    val time: Epoch,
    /** Total precipitation in mm (water equivalent). */
    val precipitation: Double,
    /** Rain in mm. */
    val rain: Double = 0.0,
    /** Snowfall in cm. */
    val snowfall: Double = 0.0,
) {
    val isWet: Boolean get() = precipitation >= wetThreshold || snowfall >= 0.1

    companion object {
        const val wetThreshold = 0.1
    }
}

class ForecastException(message: String) : Exception(message)

@Serializable
data class Forecast(
    var location: Coordinate,
    var timeZoneIdentifier: String,
    var current: CurrentConditions,
    var hourly: List<HourlyForecast>,
    var daily: List<DailyForecast>,
    var source: String,
    var fetchedAt: Epoch,
    /** Set when `current` comes from a real station observation rather than the forecast model. */
    var observation: Observation? = null,
    /** The next couple of hours in 15-minute steps. */
    var minutely: List<PrecipitationSlot> = emptyList(),
    /** Set when the radar changed "now". */
    var radar: RadarNow? = null,
    /** Where "now"'s sky came from, for the caption. nil means the forecast. */
    var skySource: String? = null,
    /** The model's own hours from yesterday 00:00 through today, unblended. */
    var recentHours: List<HourlyForecast>? = null,
    /** True when the daily highs and lows include the between-hours allowance. */
    var extremesIncludePeak: Boolean? = null,
) {
    /** A copy whose lists and nested values can be changed without touching this one. */
    fun deepCopy(): Forecast = copy(
        current = current.copy(),
        hourly = hourly.map { it.copy() },
        daily = daily.map { it.copy() },
        observation = observation?.copy(),
    )

    val cal: Cal get() = Cal(timeZoneIdentifier)

    /** The next `count` hours, starting with the hour that contains `date`. */
    fun upcomingHours(date: Epoch = nowEpoch(), count: Int = 24): List<HourlyForecast> =
        hourly.filter { it.time + 3600 > date }.take(count)

    /**
     * The next hours, with the first one showing current conditions (the same numbers as the
     * "now" card) instead of the forecast for that hour.
     */
    fun hoursStartingNow(date: Epoch = nowEpoch(), count: Int = 24,
                         unit: TemperatureUnit = UnitSettings.current.temperature): List<HourlyForecast> {
        val hours = upcomingHours(date, count).map { it.copy() }
        if (hours.isEmpty()) return hours
        val c = current
        val h0 = hours[0]
        h0.temperature = c.temperature
        h0.feelsLike = c.feelsLike
        h0.condition = c.condition
        h0.isDay = c.isDay
        h0.humidity = c.humidity ?: h0.humidity
        h0.windSpeed = c.windSpeed ?: h0.windSpeed
        h0.windDirection = c.windDirection ?: h0.windDirection
        h0.windGusts = c.windGusts ?: h0.windGusts
        return withoutRoundingBlips(hours, unit, dayExtremeTimes(date))
    }

    /** The hour of each day's highest and lowest temperature, and of tonight's low. */
    fun dayExtremeTimes(date: Epoch = nowEpoch()): Set<Epoch> {
        val calendar = cal
        val byDay = hourly.groupBy { calendar.startOfDay(it.time) }
        val out = mutableSetOf<Epoch>()
        for (hours in byDay.values) {
            hours.maxByOrNull { it.temperature }?.let { out.add(it.time) }
            hours.minByOrNull { it.temperature }?.let { out.add(it.time) }
        }
        val tonight = tonightLow(date)
        if (tonight != null) {
            hourly.firstOrNull { it.temperature == tonight && it.time > date - 3600 }?.let { out.add(it.time) }
        }
        return out
    }

    /** The forecast hour that contains `date`. */
    fun hour(date: Epoch = nowEpoch()): HourlyForecast? = upcomingHours(date, 1).firstOrNull()

    /** Today's row of the daily forecast, in the place's time zone. */
    fun day(date: Epoch = nowEpoch()): DailyForecast? {
        val calendar = cal
        return daily.firstOrNull { calendar.isSameDay(it.date, date) } ?: daily.firstOrNull()
    }

    /**
     * Lowest forecast temperature tonight: from 6 PM (or `date`, if later) through 9 AM tomorrow.
     * Before 6 AM "tonight" is the night we're in, so the window is `date` through 9 AM today.
     */
    fun tonightLow(date: Epoch = nowEpoch()): Double? {
        val calendar = cal
        val startOfToday = calendar.startOfDay(date)
        val start: Epoch
        val end: Epoch
        if (calendar.hour(date) < 6) {
            start = date
            end = startOfToday + 9 * 3600
        } else {
            start = max(date, startOfToday + 18 * 3600)
            end = startOfToday + 33 * 3600
        }
        val from = start - 3599
        return hourly.filter { it.time >= from && it.time <= end }.map { it.temperature }.minOrNull()
    }

    /**
     * A saved forecast shown later: "now" moves to the forecast hour for `date`, since the old
     * station reading and radar no longer describe it.
     */
    fun rolledForward(date: Epoch = nowEpoch()): Forecast {
        if (date - current.time <= 3600) return this
        val h = hour(date) ?: return this
        val copy = deepCopy()
        copy.current = CurrentConditions(date, h.temperature, h.feelsLike ?: h.temperature, FeelsLikeKind.apparent,
            h.humidity, h.windSpeed, h.windDirection, h.precipitation, h.condition, h.isDay, null, h.windGusts)
        copy.observation = null
        copy.radar = null
        copy.skySource = null
        return copy
    }

    /**
     * The daily rows as every screen and the widget show them: today's low is tonight's low,
     * never above today's high.
     */
    fun displayDaily(date: Epoch = nowEpoch()): List<DailyForecast> {
        val todayIndex = todayIndex(date) ?: return daily
        val rows = daily.map { it.copy() }
        val tonight = tonightLow(date)
        if (tonight != null) {
            val allowance = if (extremesIncludePeak == true) ModelBlend.lowAllowance else 0.0
            var low = tonight - allowance
            if (abs(current.time - date) < 7200) {
                low = min(low, current.temperature)
            }
            val endOfToday = cal.addingDays(cal.startOfDay(date), 1)
            val from = date - 3599
            val remMin = hourly.filter { it.time >= from && it.time <= endOfToday }.map { it.temperature }.minOrNull()
            if (remMin != null) {
                low = min(low, remMin - allowance)
            }
            rows[todayIndex].low = min(low, rows[todayIndex].high)
        }
        return rows
    }

    fun displayDay(date: Epoch = nowEpoch()): DailyForecast? {
        val rows = displayDaily(date)
        return todayIndex(date)?.let { rows[it] } ?: rows.firstOrNull()
    }

    private fun todayIndex(date: Epoch): Int? {
        val calendar = cal
        val i = daily.indexOfFirst { calendar.isSameDay(it.date, date) }
        return if (i >= 0) i else null
    }

    /** The hours that fall on `day`'s date in the forecast's time zone. */
    fun hoursOn(day: DailyForecast): List<HourlyForecast> {
        val calendar = cal
        return hourly.filter { calendar.isSameDay(it.time, day.date) }
    }

    /** Open-Meteo's daily weather code is the worst hour of the day; re-pick each day's headline. */
    fun withDailyHeadlines(): Forecast {
        val copy = deepCopy()
        copy.daily = daily.map { day ->
            val d = day.copy(summary = null)
            val hours = hoursOn(day)
            if (!d.condition.isWetOrStorm || hours.isEmpty()) return@map d
            val wetHours = hours.count { (it.precipitation ?: 0.0) >= 0.1 }
            val total = (d.rainSum ?: 0.0) + (d.snowfallSum ?: 0.0) * 0.7
            val substantial = total >= 1 || wetHours >= 3
            if ((d.precipitationProbability ?: 100.0) < headlineChance && !substantial) {
                d.condition = dryHeadline(hours)
                return@map d
            }
            val wet = hours.filter { (it.precipitation ?: 0.0) >= 0.1 || (it.snowfall ?: 0.0) > 0 || (it.rain ?: 0.0) > 0 }
            val kinds = wet.map { h ->
                when {
                    (h.snowfall ?: 0.0) > 0 && (h.rain ?: 0.0) <= 0 -> PrecipitationKind.snow
                    (h.rain ?: 0.0) > 0 && (h.snowfall ?: 0.0) <= 0 -> PrecipitationKind.rain
                    else -> if (h.temperature <= 1) PrecipitationKind.snow else PrecipitationKind.rain
                }
            }
            val first = kinds.firstOrNull() ?: return@map d
            val last = kinds.last()
            val hasRain = PrecipitationKind.rain in kinds
            val hasSnow = PrecipitationKind.snow in kinds
            if (hasRain && hasSnow) {
                d.summary = when {
                    first == PrecipitationKind.rain && last == PrecipitationKind.snow -> "Rain then snow"
                    first == PrecipitationKind.snow && last == PrecipitationKind.rain -> "Snow then rain"
                    else -> "Rain and snow"
                }
                val snowHours = kinds.count { it == PrecipitationKind.snow }
                d.condition = if (snowHours * 2 > kinds.size) WeatherCondition.snow else WeatherCondition.rain
            } else if (hasRain && (d.condition == WeatherCondition.snow || d.condition == WeatherCondition.snowShowers ||
                        d.condition == WeatherCondition.snowGrains)) {
                d.condition = WeatherCondition.rain
            } else if (hasSnow && (d.condition == WeatherCondition.rain || d.condition == WeatherCondition.rainShowers ||
                        d.condition == WeatherCondition.drizzle)) {
                d.condition = WeatherCondition.snow
            }
            d
        }
        return copy
    }

    companion object {
        /** Below this chance a day isn't headlined as rain or snow. */
        const val headlineChance = 35.0

        /**
         * A flat 6.4°, 6.5°, 6.4° reads "6°, 7°, 6°". When an hour's rounded value differs from two
         * neighbours that agree, and is within half a degree of them, it takes their average.
         * Hours in `keep` (a day's high or low) are never changed.
         */
        fun withoutRoundingBlips(hours: List<HourlyForecast>, unit: TemperatureUnit,
                                 keep: Set<Epoch> = emptySet()): List<HourlyForecast> {
            if (hours.size < 3) return hours
            val out = hours.map { it.copy() }
            for (i in 1 until hours.size - 1) {
                if (hours[i].time in keep) continue
                val a = unit.convert(hours[i - 1].temperature)
                val b = unit.convert(hours[i].temperature)
                val c = unit.convert(hours[i + 1].temperature)
                if (!(a.rnd() == c.rnd() && b.rnd() != a.rnd() && abs(b - (a + c) / 2) < 0.6)) continue
                val fixed = (hours[i - 1].temperature + hours[i + 1].temperature) / 2
                val shift = fixed - hours[i].temperature
                out[i].temperature = fixed
                out[i].feelsLike = out[i].feelsLike?.let { it + shift }
            }
            return out
        }

        /** The most common sky among the day's daylight hours, ignoring the odd wet one. */
        private fun dryHeadline(hours: List<HourlyForecast>): WeatherCondition {
            val pool = if (hours.none { it.isDay }) hours else hours.filter { it.isDay }
            return mostCommon(pool.filter { !it.condition.isPrecipitation }.map { it.condition }) ?: WeatherCondition.overcast
        }

        /** Highest count; ties go to the alphabetically first name, as in the iOS app. */
        fun mostCommon(list: List<WeatherCondition>): WeatherCondition? {
            if (list.isEmpty()) return null
            val counts = list.groupingBy { it }.eachCount()
            return counts.entries.sortedWith(compareByDescending<Map.Entry<WeatherCondition, Int>> { it.value }
                .thenBy { it.key.name }).first().key
        }
    }
}
