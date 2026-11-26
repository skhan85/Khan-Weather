package com.khanweather.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.HourlyForecast
import com.khanweather.core.PrecipitationKind
import com.khanweather.core.PrecipitationUnit
import com.khanweather.core.UnitSettings
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

    var mode by remember { mutableStateOf("Temp") }
    var selectedIndex by remember { mutableStateOf<Int?>(null) }
    val colPx = with(LocalDensity.current) { col.toPx() }
    Column {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (m in listOf("Temp", "Rain", "Snow", "Wind")) {
                val on = mode == m
                Text(
                    m,
                    style = style(12.sp, FontWeight.Bold, if (on) Color.Black else Color.White.copy(alpha = 0.85f)),
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (on) Gold else Color.White.copy(alpha = 0.12f))
                        .clickable { mode = m; selectedIndex = null }
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
        Box {
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                Column(Modifier.padding(vertical = 4.dp)) {
                    Row {
                        hours.forEachIndexed { i, h ->
                            Column(Modifier.width(col).clickable { onHour(h) }, horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                if (i == 0 && firstIsNow) GoldPill("Now", 13.sp)
                                else Text(TimeText.hour(h.time, zone), style = style(13.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.88f)),
                                    maxLines = 1, modifier = Modifier.padding(vertical = 2.dp))
                                IconBadge(h.copy().apply { promoteLikelyPrecipitation() }.condition, h.isDay, 38.dp, mixed = h.isMixedPrecipitation)
                            }
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    val scrubModifier = Modifier
                        .width(col * hours.size)
                        .height(74.dp)
                        .pointerInput(hours, colPx) {
                            fun pick(x: Float) {
                                val idx = (x / colPx).toInt()
                                if (idx in hours.indices) selectedIndex = idx
                            }
                            detectDragGesturesAfterLongPress(
                                onDragStart = { pick(it.x) },
                                onDrag = { change, _ -> change.consume(); pick(change.position.x) },
                                onDragEnd = { selectedIndex = null },
                                onDragCancel = { selectedIndex = null },
                            )
                        }
                    if (mode == "Rain" || mode == "Snow") {
                        val snowMode = mode == "Snow"
                        val maxVal = max(hours.maxOf { h ->
                            val s = h.snowfall ?: 0.0
                            if (snowMode) s else h.rain ?: if (s >= 0.1) maxOf(0.0, (h.precipitation ?: 0.0) - s * 0.7) else (h.precipitation ?: 0.0)
                        }, 2.0)
                        val inches = UnitSettings.current.precipitation == PrecipitationUnit.inches
                        Row(scrubModifier, verticalAlignment = Alignment.Bottom) {
                            for (h in hours) {
                                val snow = h.snowfall ?: 0.0
                                val amount = if (snowMode) snow else h.rain ?: if (snow >= 0.1) maxOf(0.0, (h.precipitation ?: 0.0) - snow * 0.7) else (h.precipitation ?: 0.0)
                                val pop = h.precipitationProbability ?: 0.0
                                val kindMatches = if (snowMode) (h.precipitationKind == PrecipitationKind.snow || h.precipitationKind == PrecipitationKind.mixed || h.temperature <= 1.0)
                                    else (h.precipitationKind != PrecipitationKind.snow)
                                val hasAmount = amount >= 0.1
                                val frac = if (hasAmount) minOf(1.0, amount / maxVal) else if (kindMatches && pop >= 20.0) 0.12 else 0.0
                                val lbl = when {
                                    hasAmount && snowMode && inches -> String.format(java.util.Locale.US, "%.1f\"", maxOf(0.1, amount / 2.54))
                                    hasAmount && snowMode -> String.format(java.util.Locale.US, "%.1f cm", amount)
                                    hasAmount && inches -> String.format(java.util.Locale.US, "%.1f\"", maxOf(0.1, amount / 25.4))
                                    hasAmount -> String.format(java.util.Locale.US, "%.1f", amount)
                                    kindMatches && pop >= 10.0 -> "${pop.toInt()}%"
                                    else -> "–"
                                }
                                val activeColor = when {
                                    h.isMixedPrecipitation -> Color(0xFFC7B8FF)
                                    snowMode -> Color.White
                                    else -> Color(0xFF3CE8FF)
                                }
                                val barColor = if (frac <= 0) Color.White.copy(alpha = 0.18f) else activeColor
                                val textColor = if (hasAmount || (kindMatches && pop >= 20.0)) activeColor else Color.White.copy(alpha = 0.55f)
                                Column(Modifier.width(col).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Bottom) {
                                    Text(lbl, style = style(11.sp, FontWeight.Bold, textColor), maxLines = 1)
                                    Spacer(Modifier.height(4.dp))
                                    Box(Modifier.width(18.dp).height(maxOf(3f, (frac * 46.0).toFloat()).dp).clip(RoundedCornerShape(4.dp)).background(barColor))
                                }
                            }
                        }
                    } else if (mode == "Wind") {
                        val maxW = max(hours.maxOf { it.windSpeed ?: 0.0 }, 25.0)
                        Row(scrubModifier, verticalAlignment = Alignment.Bottom) {
                            for (h in hours) {
                                val w = h.windSpeed ?: 0.0
                                val g = h.windGusts ?: 0.0
                                val frac = minOf(1.0, w / maxW)
                                val barColor = if (g >= 50.0) Color(0xFFFF9800) else Gold
                                Column(Modifier.width(col).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Bottom) {
                                    Text(WeatherFormat.wind(w), style = style(10.sp, FontWeight.Bold), maxLines = 1)
                                    Spacer(Modifier.height(4.dp))
                                    Box(Modifier.width(18.dp).height(maxOf(4f, (frac * 44.0).toFloat()).dp).clip(RoundedCornerShape(4.dp)).background(barColor))
                                }
                            }
                        }
                    } else Canvas(scrubModifier) {
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
                            val active = i == selectedIndex
                            drawCircle(if (active) Gold else Color.White, (if (active) 5.2f else if (i == 0) 4.4f else 3f) * density, p)
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
            val idx = selectedIndex
            if (idx != null && idx in hours.indices) {
                ScrubBanner(hours[idx], zone, Modifier.align(Alignment.TopCenter).padding(top = 2.dp))
            }
        }
    }
}

@Composable
private fun ScrubBanner(hour: HourlyForecast, zone: String, modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.45f))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(TimeText.hour(hour.time, zone), style = style(12.sp, FontWeight.SemiBold, Gold))
        Text(WeatherFormat.temperature(hour.temperature), style = style(12.sp, FontWeight.Bold))
        hour.feelsLike?.let {
            Text("Feels ${WeatherFormat.temperature(it)}", style = style(11.sp, color = Color.White.copy(alpha = 0.8f)))
        }
        hour.windSpeed?.let {
            Text(WeatherFormat.wind(it), style = style(11.sp, color = Color.White.copy(alpha = 0.8f)))
        }
        hour.rain?.takeIf { it >= 0.05 }?.let {
            Text(WeatherFormat.rainAmount(it), style = style(11.sp, color = Color.White.copy(alpha = 0.8f)))
        }
        hour.snowfall?.takeIf { it >= 0.05 }?.let {
            Text(WeatherFormat.snowAmount(it), style = style(11.sp, color = Color.White.copy(alpha = 0.8f)))
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

