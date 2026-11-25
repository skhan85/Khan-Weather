package com.khanweather.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.*
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.time.ZoneId

/**
 * Writes down tomorrow's forecast from each model, and later checks it against what Environment
 * Canada's nearest climate station (or the local station readings) recorded. Runs for the
 * current location only. Port of the iOS AccuracyTracker.swift.
 */
object AccuracyTracker {
    private const val LOG_KEY = "accuracyLog"
    private const val LAST_RUN_KEY = "accuracyLastRun"
    private const val LOCAL_KEY = "accuracyLocalRanges"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val rangesSerializer = MapSerializer(String.serializer(), AccuracyLog.LocalRange.serializer())

    var log: AccuracyLog
        get() = Prefs.prefs.getString(LOG_KEY, null)?.let { runCatching { json.decodeFromString(AccuracyLog.serializer(), it) }.getOrNull() } ?: AccuracyLog()
        set(v) { Prefs.prefs.edit().putString(LOG_KEY, json.encodeToString(AccuracyLog.serializer(), v)).apply() }

    private var localRanges: Map<String, AccuracyLog.LocalRange>
        get() = Prefs.prefs.getString(LOCAL_KEY, null)?.let { runCatching { json.decodeFromString(rangesSerializer, it) }.getOrNull() } ?: emptyMap()
        set(v) { Prefs.prefs.edit().putString(LOCAL_KEY, json.encodeToString(rangesSerializer, v)).apply() }

    /** Notes the day's temperature range from a nearby station (up to 25 km away when no hyperlocal reading exists). */
    private fun recordObservation(obs: Observation?, shown: Double, zone: ZoneId, now: Epoch) {
        if (obs == null) return
        val sample = when {
            obs.isLocal && shown.isFinite() -> shown
            (obs.distanceKm ?: Double.POSITIVE_INFINITY) <= 25.0 && obs.temperature.isFinite() -> obs.temperature
            else -> return
        }
        val today = AccuracyLog.dayString(now, zone)
        val night = AccuracyLog.LocalRange.isNight(now, zone)
        val ranges = localRanges.toMutableMap()
        val existing = ranges[today]
        if (existing != null) existing.add(sample, obs.stationName, night)
        else ranges[today] = AccuracyLog.LocalRange.start(today, sample, obs.stationName, night)
        // Keep about two weeks.
        val oldest = AccuracyLog.dayString(now, zone, offsetDays = -14)
        localRanges = ranges.filterKeys { it >= oldest }
    }

    @Synchronized private fun claimRun(now: Epoch): Boolean {
        val last = Prefs.prefs.getLong(LAST_RUN_KEY, 0L).toDouble()
        if (now - last < 3 * 3600) return false
        Prefs.prefs.edit().putLong(LAST_RUN_KEY, now.toLong()).apply()
        return true
    }

    suspend fun update(forecast: Forecast, now: Epoch = nowEpoch()) {
        val zone = forecast.cal.zone
        val location = forecast.location
        synchronized(this) { recordObservation(forecast.observation, forecast.current.temperature, zone, now) }
        if (!claimRun(now)) return
        val log = this.log
        val today = AccuracyLog.dayString(now, zone)
        val tomorrow = AccuracyLog.dayString(now, zone, offsetDays = 1)

        if (log.forecasts.none { it.day == tomorrow }) {
            val rows = runCatching { ModelComparisonProvider().days(location) }.getOrNull()
            if (rows != null) {
                val next = rows.filter { AccuracyLog.dayString(it.date, zone) == tomorrow }
                val highs = mutableMapOf<String, Double>(); val lows = mutableMapOf<String, Double>()
                for (row in next) {
                    row.high?.let { highs[row.model.raw] = it }
                    row.low?.let { lows[row.model.raw] = it }
                }
                if (highs.isNotEmpty()) log.record(AccuracyLog.Forecast(tomorrow, highs, lows))
            }
        }

        // Climate stations post a day's record the next morning or so; try the three oldest open days.
        // A day the climate station still hasn't posted after a full extra day falls back to the
        // local readings, if they covered the night and the day.
        val ranges = localRanges
        for (day in log.unscoredDays(before = today).takeLast(3)) {
            val seen = runCatching { ClimateDailyProvider().observed(day, location) }.getOrNull()
            val local = ranges[day]
            if (seen != null) log.record(seen)
            else if (local != null && local.usable(today)) log.record(AccuracyLog.Observed(day, local.high, local.low, local.station))
        }
        this.log = log
    }
}

/** How close each model's day-ahead high and low have been to what was recorded. */
@Composable
fun AccuracyScreen() {
    val log = remember { AccuracyTracker.log }
    val scores = remember(log) { log.scores() }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        Section("Average miss, day-ahead", Icons.Filled.TrackChanges) {
            if (scores.isEmpty()) {
                Text("Khan Weather writes down tomorrow's forecast from every model each day, then checks it against Environment Canada's nearest climate station or nearby station readings. Results show here after the first day is checked, usually within two days.",
                    style = style(15.sp, FontWeight.Medium))
            } else {
                scores.forEachIndexed { rank, score ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("${rank + 1}", style = style(17.sp, FontWeight.Black, if (rank == 0) Gold else Color.White.copy(alpha = 0.7f)),
                            modifier = Modifier.width(26.dp))
                        Column(Modifier.weight(1f)) {
                            Text(score.model.displayName, style = style(15.sp, FontWeight.Bold))
                            Text("${score.days} day${if (score.days == 1) "" else "s"} checked", style = style(12.sp, color = Color.White.copy(alpha = 0.7f)))
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("High ±${error(score.highError)}", style = style(12.sp, FontWeight.SemiBold))
                            Text("Low ±${error(score.lowError)}", style = style(12.sp, FontWeight.SemiBold))
                        }
                    }
                    if (rank < scores.size - 1) RowDivider()
                }
            }
        }
        val station = log.observed.lastOrNull()?.let { " Checked against ${it.station}." } ?: ""
        Text("Tracks your current location over the last ${AccuracyLog.KEEP_DAYS} days.$station Smaller is better.",
            style = style(12.sp, color = Color.White.copy(alpha = 0.8f)), modifier = Modifier.padding(horizontal = 32.dp).padding(bottom = 14.dp))
    }
}

/** An error in the user's temperature unit, one decimal. */
private fun error(celsius: Double): String {
    val value = if (UnitSettings.current.temperature != TemperatureUnit.celsius) celsius * 9 / 5 else celsius
    return fmt("%.1f°", value)
}
