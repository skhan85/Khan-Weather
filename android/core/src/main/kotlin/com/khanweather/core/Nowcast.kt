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
            if (snow > 0 && rain >= PrecipitationSlot.wetThreshold) return Kind.mixed
            return if (snow > 0) Kind.snow else Kind.rain
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
        val isSnow = r.isSnowing && !r.isRaining
        slots[0] = PrecipitationSlot(slots[0].time, slotAmount, if (isSnow) 0.0 else slotAmount, if (isSnow) slotAmount else 0.0)
    }
    return slots
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
