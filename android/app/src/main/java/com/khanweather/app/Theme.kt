package com.khanweather.app

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import com.khanweather.core.WeatherCondition
import com.khanweather.core.WeatherCondition.*
import kotlin.math.max
import kotlin.math.min

/** Khan Weather's own accent: a warm gold used for highlights on the sky. */
val Gold = Color(1.0f, 0.78f, 0.32f)
val White82 = Color.White.copy(alpha = 0.82f)

fun rgb(r: Double, g: Double, b: Double) = Color(r.toFloat(), g.toFloat(), b.toFloat())

/** Colour pair and extra layer for one kind of sky, the same as the iPhone app. */
data class Sky(val top: Color, val bottom: Color, val decoration: Decoration) {
    enum class Decoration { plain, sunGlow, stars, haze }

    companion object {
        private enum class Group { clear, partly, grey, wet, snow, storm }

        private fun group(c: WeatherCondition): Group = when (c) {
            WeatherCondition.clear -> Group.clear
            mainlyClear, partlyCloudy -> Group.partly
            overcast, mostlyCloudy, fog, unknown -> Group.grey
            drizzle, rain, rainShowers, freezingDrizzle, freezingRain -> Group.wet
            snow, snowGrains, snowShowers -> Group.snow
            thunderstorm, thunderstormHail -> Group.storm
        }

        fun of(condition: WeatherCondition, isDay: Boolean): Sky {
            val g = group(condition)
            return if (isDay) when (g) {
                Group.clear -> Sky(rgb(0.16, 0.45, 0.86), rgb(0.40, 0.68, 0.96), Decoration.sunGlow)
                Group.partly -> Sky(rgb(0.24, 0.47, 0.78), rgb(0.52, 0.68, 0.88), Decoration.plain)
                Group.grey -> Sky(rgb(0.36, 0.42, 0.50), rgb(0.56, 0.61, 0.68), Decoration.haze)
                Group.wet -> Sky(rgb(0.24, 0.32, 0.43), rgb(0.42, 0.50, 0.60), Decoration.plain)
                Group.snow -> Sky(rgb(0.38, 0.48, 0.62), rgb(0.62, 0.70, 0.80), Decoration.haze)
                Group.storm -> Sky(rgb(0.18, 0.18, 0.30), rgb(0.34, 0.34, 0.46), Decoration.plain)
            } else when (g) {
                Group.clear -> Sky(rgb(0.03, 0.06, 0.18), rgb(0.12, 0.19, 0.38), Decoration.stars)
                Group.partly -> Sky(rgb(0.06, 0.09, 0.20), rgb(0.18, 0.23, 0.36), Decoration.stars)
                Group.grey, Group.snow -> Sky(rgb(0.10, 0.12, 0.18), rgb(0.23, 0.26, 0.33), Decoration.plain)
                Group.wet, Group.storm -> Sky(rgb(0.07, 0.09, 0.15), rgb(0.17, 0.20, 0.28), Decoration.plain)
            }
        }
    }
}

/** Colours for temperatures, cold violet through warm red. Takes °C. */
object TemperatureColor {
    private val stops = listOf(
        -25.0 to Triple(0.62, 0.50, 1.00),
        -10.0 to Triple(0.38, 0.62, 1.00),
        0.0 to Triple(0.36, 0.86, 0.96),
        10.0 to Triple(0.46, 0.88, 0.52),
        20.0 to Triple(1.00, 0.84, 0.30),
        30.0 to Triple(1.00, 0.56, 0.24),
        40.0 to Triple(0.96, 0.30, 0.30),
    )

    fun color(celsius: Double): Color {
        val t = min(max(celsius, stops.first().first), stops.last().first)
        for (i in 1 until stops.size) {
            if (t <= stops[i].first) {
                val (t0, c0) = stops[i - 1]
                val (t1, c1) = stops[i]
                val f = (t - t0) / (t1 - t0)
                return rgb(c0.first + (c1.first - c0.first) * f, c0.second + (c1.second - c0.second) * f,
                    c0.third + (c1.third - c0.third) * f)
            }
        }
        val c = stops.last().second
        return rgb(c.first, c.second, c.third)
    }

    /** High on the left, low on the right. */
    fun gradient(low: Double, high: Double): Brush =
        Brush.horizontalGradient((0..4).map { color(high - (high - low) * it / 4.0) })
}

val ChanceBlue = rgb(0.52, 0.80, 1.0)
val ChanceSnow = rgb(0.75, 0.92, 1.0)
val ColdBlue = rgb(0.62, 0.84, 1.0)
