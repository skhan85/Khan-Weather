package com.khanweather.core

import kotlinx.serialization.Serializable
import kotlin.math.abs

/**
 * What the relay learned about the forecast at one place (GET /v1/learned, tools/learn/learner.py):
 * the blend's own error there by 3-hour block of the day, and how often it really rains when the
 * chance says it might. A correction is `enabled` only once it has beaten the plain forecast on the
 * last 14 days, each day corrected with what was known before it.
 */
@Serializable
data class LearnedCorrections(
    val status: String? = null,
    val days: Int? = null,
    val temperature: Temperature? = null,
    val rain: Rain? = null,
) {
    @Serializable
    data class Temperature(
        val enabled: Boolean = false,
        /** °C to subtract, 8 blocks of 3 hours from 00 UTC (positive = forecast runs warm here). */
        val bias_3h: List<Double>? = null,
        val mae_raw: Double? = null,
        val mae_learned: Double? = null,
        val checked_days: Int? = null,
        val truth: String? = null,
    ) {
        val provenBins: List<Double>?
            get() = bias_3h?.takeIf { enabled && it.size == 8 && it.all { v -> v.isFinite() && abs(v) <= 3 } }
    }

    @Serializable
    data class Rain(
        val enabled: Boolean = false,
        val pop_factor: Double? = null,
        val brier_raw: Double? = null,
        val brier_learned: Double? = null,
        val wet_hours: Int? = null,
        val truth: String? = null,
    )

    /** One or two plain sentences for the compare screen. */
    val summary: String
        get() {
            val d = days ?: 0
            val parts = mutableListOf<String>()
            val t = temperature
            if (t != null && t.enabled && t.mae_raw != null && t.mae_learned != null && t.bias_3h != null) {
                val worst = t.bias_3h.maxByOrNull { abs(it) } ?: 0.0
                val way = if (worst > 0) "warm" else "cold"
                val k = if (UnitSettings.current.temperature == TemperatureUnit.fahrenheit) 1.8 else 1.0
                parts += fmt("temperatures here ran up to %.1f° %s at some hours, now corrected (checked error %.1f° → %.1f°)",
                    abs(worst) * k, way, t.mae_raw * k, t.mae_learned * k)
            }
            val r = rain
            if (r != null && r.enabled && r.pop_factor != null) {
                parts += if (r.pop_factor < 1) "rain came less often than the chance said, so chances here are scaled down"
                else "rain came more often than the chance said, so chances here are scaled up"
            }
            if (parts.isEmpty()) {
                return if (d < 10) "Learning this place: $d of 10 days so far. Nothing is corrected until it proves itself."
                else "Checked over $d days here: no correction has proven itself yet, so the forecast is left as is."
            }
            return "Learned here over $d days: " + parts.joinToString("; ") + "."
        }
}
