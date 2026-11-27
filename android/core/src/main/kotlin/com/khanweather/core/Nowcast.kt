@file:Suppress("EnumEntryName")

package com.khanweather.core

import kotlin.math.max

/** "Rain starting in about 20 min" style summary of the next two hours. */
data class Nowcast(val kind: Kind, val change: Change) {
    enum class Kind(val noun: String) { rain("Rain"), snow("Snow"), mixed("Rain and snow") }

    sealed class Change {
        data class Starting(val minutes: Int) : Change()
        data class Stopping(val minutes: Int) : Change()
        /** Wet now and for the whole window. */
        data object Continuing : Change()
    }

    val text: String
        get() = when (val c = change) {
            is Change.Starting -> "${kind.noun} starting in about ${duration(c.minutes)}"
            is Change.Stopping -> "${kind.noun} stopping in about ${duration(c.minutes)}"
            Change.Continuing -> "${kind.noun} for at least the next 2 hours"
        }

    /** Fits a small widget: "Rain in 25 min", "Snow ends in 1 hr". */
    val shortText: String
        get() = when (val c = change) {
            is Change.Starting -> "${kind.noun} in ${duration(c.minutes)}"
            is Change.Stopping -> "${kind.noun} ends in ${duration(c.minutes)}"
            Change.Continuing -> "${kind.noun} next 2 hr"
        }

    companion object {
        fun duration(minutes: Int): String {
            val h = minutes / 60
            val m = minutes % 60
            return when {
                h == 0 -> "$m min"
                m == 0 -> "$h hr"
                else -> "$h hr $m min"
            }
        }

        fun kind(slots: List<PrecipitationSlot>): Kind {
            var rain = 0.0
            var snow = 0.0
            for (s in slots) { rain += s.rain; snow += s.snowfall }
            return when (PrecipitationSlot.kindOf(rain, snow)) {
                PrecipitationKind.rain -> Kind.rain
                PrecipitationKind.snow -> Kind.snow
                PrecipitationKind.mixed -> Kind.mixed
            }
        }

        /** Minutes from `now` to `date`, rounded to 5 and at least 5. */
        fun minutes(now: Epoch, date: Epoch): Int {
            val raw = max(0.0, date - now) / 60
            return max(5, (raw / 5).rnd().toInt() * 5)
        }
    }
}

const val nowcastWindow = 2.0 * 3600

/**
 * The 15-minute slots of the next two hours that the nowcast reads, with live gauges and radar
 * folded into the current slot. Empty when the data is missing or stale.
 */
fun Forecast.nowcastSlots(now: Epoch = nowEpoch()): List<PrecipitationSlot> {
    val slots = minutely.filter { it.time + 900 > now && it.time < now + nowcastWindow }.sortedBy { it.time }.toMutableList()
    if (slots.isEmpty() || slots[0].time > now) return emptyList()
    val r = radar
    if (observation?.gaugesSayDry == true && r?.isPrecipitating != true && current.temperature > 1 && slots[0].snowfall == 0.0) {
        slots[0] = PrecipitationSlot(slots[0].time, 0.0, 0.0, 0.0)
    } else if (r != null && r.isPrecipitating && !slots[0].isWet) {
        val hourlyRate = max(r.rainMmPerHour, r.snowCmPerHour)
        val slotAmount = max(PrecipitationSlot.wetThreshold, hourlyRate / 4.0)
        val rainPart = if (r.isRaining) max(if (r.isSnowing) PrecipitationSlot.wetThreshold else slotAmount, r.rainMmPerHour / 4.0) else 0.0
        val snowPart = if (r.isSnowing) max(if (r.isRaining) PrecipitationSlot.wetThreshold else slotAmount, r.snowCmPerHour / 4.0) else 0.0
        slots[0] = PrecipitationSlot(slots[0].time, max(slotAmount, rainPart + snowPart), rainPart, snowPart)
    }
    // The Now card and this line must agree: card wet now but slot dry -> a light amount now.
    // When more is due within the hour, the dry gap before it is filled too.
    if (!slots[0].isWet && current.condition.isPrecipitation) {
        val snow = !current.condition.isRainLike
        val w = PrecipitationSlot.wetThreshold
        val nextWet = slots.indexOfFirst { it.isWet }
        val fill = if (nextWet in 1..drizzleLeadSlots) nextWet else 1
        for (i in 0 until fill) slots[i] = PrecipitationSlot(slots[i].time, w, if (snow) 0.0 else w, if (snow) w / 0.7 else 0.0)
    }
    // Same rain-or-snow call as the hour's (models' vote): no "Mixed" for a trace of model snow in rain.
    return slots.map { s ->
        if (!s.isWet || (s.rain <= 0.0 && s.snowfall <= 0.0)) return@map s
        val models = modelPrecipitationKind(s.time) ?: return@map s
        val temp = hourly.lastOrNull { it.time <= s.time }?.temperature ?: current.temperature
        val typed = RadarNow(s.rain, s.snowfall, s.time).typed(temp, models)
        when {
            typed.snowCmPerHour == 0.0 -> PrecipitationSlot(s.time, s.precipitation, max(s.rain, s.precipitation), 0.0)
            typed.rainMmPerHour == 0.0 -> PrecipitationSlot(s.time, s.precipitation, 0.0, max(s.snowfall, s.precipitation / 0.7))
            else -> s
        }
    }
}

/**
 * The Now card follows the first 15 minutes of Next 2 hours when those are wet and the card isn't
 * (27 Nov, 8:54 am: "Overcast" under "Rain for at least the next 2 hours" while it drizzled).
 */
fun Forecast.agreeingNowWithNowcast(now: Epoch = nowEpoch()): Forecast {
    val c = current.condition
    if (c.isPrecipitation || c == WeatherCondition.thunderstorm || c == WeatherCondition.thunderstormHail) return this
    val slots = nowcastSlots(now)
    val first = slots.firstOrNull() ?: return this
    if (!first.isWet) return drizzlingRadarCantSee(slots)
    val copy = deepCopy()
    val text: String
    when (first.kind) {
        PrecipitationKind.snow -> {
            copy.current.condition = WeatherCondition.snow
            val r = first.snowfall * 4
            text = if (r < 0.5) "Light snow" else if (r < 1) "Moderate snow" else "Heavy snow"
        }
        PrecipitationKind.mixed -> {
            copy.current.condition = if (current.temperature <= 0) WeatherCondition.freezingRain else WeatherCondition.rain
            text = "Rain and snow"
        }
        PrecipitationKind.rain -> {
            val r = max(first.rain, first.precipitation) * 4
            copy.current.condition = if (r < 0.5) WeatherCondition.drizzle else WeatherCondition.rain
            text = if (r < 0.5) "Drizzle" else if (r < 2.5) "Light rain" else if (r < 7.6) "Moderate rain" else "Heavy rain"
        }
    }
    copy.observation?.conditionText = text
    return copy
}

/** Share of the blend's models (at least 3) with measurable rain (0.2 mm) in the hour holding now. */
val Forecast.modelWetShareNow: Double?
    get() {
        val h = hourly.lastOrNull { it.time <= current.time } ?: return null
        if (current.time - h.time >= 3600) return null
        val n = h.modelCount ?: return null
        val w = h.modelsWet ?: return null
        return if (n >= 3) w.toDouble() / n else null
    }
/** Stations or airports within 40 km reporting rain or drizzle that make it "widespread". */
const val widespreadWetReports = 2
/** Share of models wet now that, in damp air under cloud, says it's drizzling. */
const val modelsWetDrizzleShare = 0.5

/** Rain this many 15-minute slots away (an hour) counts as "due" for drizzle. */
const val drizzleLeadSlots = 4
/** Without a nearby drizzle report, the air must be at least this damp (%). */
const val damperDrizzleHumidity = 90.0

/**
 * Drizzle that neither the radar nor the 15-minute data shows (27 Nov, 10:36 am in Milton: drizzling,
 * card "Overcast", radar dry, "Rain starting in about 40 min"). Either says it is drizzling: an airport
 * or station within 40 km reports drizzle, with damp air and cloud here; or very damp air under cloud
 * with rain due within the hour.
 */
fun Forecast.drizzlingRadarCantSee(slots: List<PrecipitationSlot>): Forecast {
    val c = current.condition
    if (c != WeatherCondition.overcast && c != WeatherCondition.partlyCloudy && c != WeatherCondition.fog) return this
    if (current.temperature <= -3 || current.temperature >= 15 || radar?.isPrecipitating == true) return this
    val rh = current.humidity?.toDouble() ?: return this
    val nearby = observation?.nearbyDrizzleStation
    val rainSoon = slots.take(drizzleLeadSlots).any { it.isWet && it.kind == PrecipitationKind.rain }
    val source = if (nearby != null && rh >= drizzleHumidity && c != WeatherCondition.partlyCloudy) {
        val km = observation?.nearbyDrizzleKm?.let { ", ${WeatherFormat.roughDistance(it)} away" } ?: ""
        "drizzle reported at $nearby$km (radar can't see drizzle)"
    } else if ((observation?.nearbyWetStations?.size ?: 0) >= widespreadWetReports && current.temperature > 1 &&
        rh >= damperDrizzleHumidity && c != WeatherCondition.partlyCloudy) {
        "light rain reported at ${observation!!.nearbyWetStations!!.take(2).joinToString(" and ")} (radar can't see it here)"
    } else if (rainSoon && rh >= damperDrizzleHumidity && c != WeatherCondition.partlyCloudy) {
        "damp air with rain due within the hour (radar can't see drizzle)"
    } else if ((modelWetShareNow ?: 0.0) >= modelsWetDrizzleShare && current.temperature > 1 &&
        rh >= damperDrizzleHumidity && c != WeatherCondition.partlyCloudy) {
        "most forecast models have light rain falling now (radar can't see drizzle)"
    } else return this
    val copy = deepCopy()
    val freezing = current.temperature <= 0
    copy.current.condition = if (freezing) WeatherCondition.freezingDrizzle else WeatherCondition.drizzle
    copy.observation?.conditionText = if (freezing) "Freezing drizzle" else "Drizzle"
    copy.skySource = source
    return copy
}

/** What precipitation is doing over the next two hours, or null when it stays dry. */
fun Forecast.nowcast(now: Epoch = nowEpoch()): Nowcast? {
    val slots = nowcastSlots(now)
    if (slots.isEmpty()) return null
    if (slots[0].isWet) {
        val run = slots.takeWhile { it.isWet }
        val kind = Nowcast.kind(run)
        val dry = slots.firstOrNull { !it.isWet }
        return if (dry != null) Nowcast(kind, Nowcast.Change.Stopping(Nowcast.minutes(now, dry.time)))
        else Nowcast(kind, Nowcast.Change.Continuing)
    }
    val start = slots.indexOfFirst { it.isWet }
    if (start < 0) return null
    val run = slots.drop(start).takeWhile { it.isWet }
    return Nowcast(Nowcast.kind(run), Nowcast.Change.Starting(Nowcast.minutes(now, slots[start].time)))
}

/** When a "rain starting soon" notification is worth sending. */
object RainHeadsUp {
    const val lookAhead = 60
    const val quietPeriod = 3.0 * 3600

    fun shouldNotify(nowcast: Nowcast?, lastNotified: Epoch?, now: Epoch = nowEpoch()): Nowcast? {
        val c = nowcast?.change as? Nowcast.Change.Starting ?: return null
        if (c.minutes > lookAhead) return null
        if (lastNotified != null && now - lastNotified < quietPeriod) return null
        return nowcast
    }

    /** The first wet hour, between `from` seconds and `within` hours ahead, that most models agree on. */
    fun upcomingWetHour(hourly: List<HourlyForecast>, now: Epoch = nowEpoch(), from: Double = 0.0,
                        within: Int = 6): Pair<Epoch, Boolean>? {
        fun wet(h: HourlyForecast): Boolean {
            val amount = (h.precipitation ?: 0.0) >= 0.3 || (h.rain ?: 0.0) >= 0.3 || (h.snowfall ?: 0.0) >= 0.3
            if (!amount) return false
            val n = h.modelCount
            val w = h.modelsWet
            if (n != null && n > 0 && w != null) return w.toDouble() / n >= 0.6
            return (h.precipitationProbability ?: 100.0) >= 60
        }
        val sorted = hourly.sortedBy { it.time }
        val current = sorted.lastOrNull { it.time <= now }
        if (current != null && current.time + 3600 > now && wet(current)) return null
        val end = now + within * 3600.0
        val h = sorted.firstOrNull { it.time > now + from && it.time <= end && wet(it) } ?: return null
        return h.time to ((h.snowfall ?: 0.0) > 0 && (h.rain ?: 0.0) < 0.3)
    }
}

/** Heads-ups that fire only when most of the blended models agree. */
object ModelAgreement {
    fun wetAgrees(hourly: List<HourlyForecast>, now: Epoch = nowEpoch(), hours: Int = 2): Boolean {
        val window = hourly.filter { it.time + 3600 > now && it.time < now + hours * 3600.0 }
        val counted = window.mapNotNull { h ->
            val n = h.modelCount
            val wet = h.modelsWet
            if (n != null && n > 0 && wet != null) wet.toDouble() / n else null
        }
        val best = counted.maxOrNull() ?: return true
        return best >= 0.5
    }

    data class Frost(val agreeing: Int, val total: Int, val time: Epoch)

    fun frost(forecast: Forecast, now: Epoch = nowEpoch(), hours: Int = 16): Frost? {
        if (forecast.current.temperature <= 0.5) return null
        val window = forecast.hourly.filter { it.time > now && it.time <= now + hours * 3600.0 }
        var best: Frost? = null
        for (h in window) {
            val n = h.modelCount ?: continue
            val cold = h.modelsFreezing ?: continue
            if (n < 3 || cold < kotlin.math.ceil(n * 0.6)) continue
            val b = best
            if (b == null || cold.toDouble() / n > b.agreeing.toDouble() / b.total) best = Frost(cold, n, h.time)
        }
        return best
    }
}
