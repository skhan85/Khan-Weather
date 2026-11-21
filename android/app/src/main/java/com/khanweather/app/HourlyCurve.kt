package com.khanweather.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.HourlyForecast
import com.khanweather.core.WeatherFormat
import kotlin.math.max

/**
 * The next hours as a scrolling strip: time and icon on top, a temperature curve with the
 * numbers on it, and the chance of rain or snow underneath. Tap a column for that hour.
 */
@Composable
fun HourlyCurve(hours: List<HourlyForecast>, zone: String, firstIsNow: Boolean, onHour: (HourlyForecast) -> Unit) {
    if (hours.isEmpty()) return
    val col = 58.dp
    val low = hours.minOf { minOf(it.temperature, it.modelLow ?: it.temperature) }
    val high = hours.maxOf { maxOf(it.temperature, it.modelHigh ?: it.temperature) }
    val span = max(high - low, 4.0)
    val floor = low - span * 0.6
    val top = high + span * 0.9
    val measurer = rememberTextMeasurer()
    val labelStyle = style(15.sp, FontWeight.Bold, shadow = true)

    Row(Modifier.horizontalScroll(rememberScrollState())) {
        Column(Modifier.padding(vertical = 4.dp)) {
            Row {
                hours.forEachIndexed { i, h ->
                    Column(Modifier.width(col).clickable { onHour(h) }, horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (i == 0 && firstIsNow) GoldPill("Now", 13.sp)
                        else Text(TimeText.hour(h.time, zone), style = style(13.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.88f)),
                            maxLines = 1, modifier = Modifier.padding(vertical = 2.dp))
                        IconBadge(h.condition, h.isDay, 38.dp)
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
            Canvas(Modifier.width(col * hours.size).height(74.dp)) {
                val cw = col.toPx()
                fun x(i: Int) = cw * i + cw / 2
                fun y(t: Double) = (size.height * (1 - (t - floor) / (top - floor))).toFloat()
                // Where the models spread: the faint band behind the line.
                val banded = hours.withIndex().filter { it.value.modelLow != null && it.value.modelHigh != null }
                if (banded.size > 1) {
                    val upper = banded.map { Offset(x(it.index), y(it.value.modelHigh!!)) }
                    val lower = banded.map { Offset(x(it.index), y(it.value.modelLow!!)) }.reversed()
                    val band = Path()
                    catmullRom(band, upper, moveFirst = true)
                    band.lineTo(lower.first().x, lower.first().y)
                    catmullRom(band, lower, moveFirst = false)
                    band.close()
                    drawPath(band, Color.White.copy(alpha = 0.16f))
                }
                val pts = hours.mapIndexed { i, h -> Offset(x(i), y(h.temperature)) }
                val area = Path()
                catmullRom(area, pts, moveFirst = true)
                area.lineTo(pts.last().x, size.height); area.lineTo(pts.first().x, size.height); area.close()
                drawPath(area, Brush.verticalGradient(listOf(Gold.copy(alpha = 0.35f), Gold.copy(alpha = 0f)),
                    startY = pts.minOf { it.y }, endY = size.height))
                val line = Path()
                catmullRom(line, pts, moveFirst = true)
                drawPath(line, Gold, style = Stroke(3.dp.toPx(), cap = StrokeCap.Round))
                pts.forEachIndexed { i, p ->
                    drawCircle(Color.White, (if (i == 0) 4.4f else 3f) * density, p)
                    val label = measurer.measure(WeatherFormat.temperature(hours[i].temperature), labelStyle)
                    drawText(label, topLeft = Offset(p.x - label.size.width / 2f, p.y - label.size.height - 6.dp.toPx()))
                }
            }
            Row {
                for (h in hours) {
                    Box(Modifier.width(col).height(16.dp), contentAlignment = Alignment.Center) {
                        PrecipChance(h.precipitationProbability, h.precipitationKind, 12.sp)
                    }
                }
            }
        }
    }
}

/** Smooth curve through the points (Catmull-Rom as cubic Béziers). */
fun catmullRom(path: Path, pts: List<Offset>, moveFirst: Boolean) {
    if (pts.isEmpty()) return
    if (moveFirst) path.moveTo(pts[0].x, pts[0].y) else path.lineTo(pts[0].x, pts[0].y)
    for (i in 0 until pts.size - 1) {
        val p0 = pts[if (i == 0) 0 else i - 1]
        val p1 = pts[i]
        val p2 = pts[i + 1]
        val p3 = pts[if (i + 2 < pts.size) i + 2 else i + 1]
        path.cubicTo(p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6,
            p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6, p2.x, p2.y)
    }
}

