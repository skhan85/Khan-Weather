package com.khanweather.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.truncate

/**
 * Times are seconds since 1970 as a Double, the same as Swift's `Date.timeIntervalSince1970`,
 * so every comparison and interpolation in the iOS app ports one for one.
 */
typealias Epoch = Double

fun nowEpoch(): Epoch = System.currentTimeMillis() / 1000.0

/** Swift's `.rounded()`: halves round away from zero (Kotlin's `round` rounds halves to even). */
fun Double.rnd(): Double {
    if (isNaN() || isInfinite()) return this
    val t = truncate(this)
    val frac = abs(this - t)
    return when {
        frac > 0.5 -> t + (if (this > 0) 1 else -1)
        frac < 0.5 -> t
        else -> t + (if (this > 0) 1 else -1)
    }
}

fun Double.rndInt(): Int = rnd().toInt()

/** Swift's `Calendar` in one time zone. */
class Cal(val zone: ZoneId) {
    constructor(id: String) : this(zoneOf(id))

    private fun zdt(t: Epoch): ZonedDateTime = Instant.ofEpochSecond(floor(t).toLong()).atZone(zone)

    fun localDate(t: Epoch): LocalDate = zdt(floorSec(t)).toLocalDate()

    fun startOfDay(t: Epoch): Epoch = localDate(t).atStartOfDay(zone).toEpochSecond().toDouble()

    fun isSameDay(a: Epoch, b: Epoch): Boolean = localDate(a) == localDate(b)

    fun hour(t: Epoch): Int = zdt(floorSec(t)).hour

    /** `calendar.date(byAdding: .day, value: n, to: t)`: same wall-clock time, n days on. */
    fun addingDays(t: Epoch, n: Int): Epoch {
        val z = zdt(floorSec(t))
        val frac = t - floorSec(t)
        return z.plusDays(n.toLong()).toEpochSecond().toDouble() + frac
    }

    /** `calendar.date(bySettingHour:minute:second:of:)`. */
    fun settingHour(t: Epoch, hour: Int, minute: Int = 0): Epoch =
        localDate(t).atTime(hour, minute).atZone(zone).toEpochSecond().toDouble()

    fun monthDay(t: Epoch): Pair<Int, Int> {
        val d = localDate(t)
        return d.monthValue to d.dayOfMonth
    }

    companion object {
        fun zoneOf(id: String?): ZoneId = try {
            if (id == null) ZoneId.systemDefault() else ZoneId.of(id)
        } catch (e: Exception) {
            ZoneId.systemDefault()
        }

        private fun floorSec(t: Epoch): Epoch = floor(t)
    }
}

/** "2026-11-15T14:00:00Z" or with fractional seconds or an offset. */
fun parseIsoDate(s: String): Epoch? = try {
    val i = java.time.OffsetDateTime.parse(s).toInstant()
    i.epochSecond + i.nano / 1e9
} catch (e: Exception) {
    try {
        val i = Instant.parse(s)
        i.epochSecond + i.nano / 1e9
    } catch (e: Exception) {
        null
    }
}

fun isoString(t: Epoch): String = Instant.ofEpochSecond(floor(t).toLong()).toString()
