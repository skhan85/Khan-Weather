package com.khanweather.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.AQICategory
import com.khanweather.core.AirQuality
import com.khanweather.core.rndInt
import kotlin.math.max
import kotlin.math.min

fun aqiColor(c: AQICategory): Color = when (c) {
    AQICategory.good -> rgb(0.36, 0.84, 0.45)
    AQICategory.moderate -> rgb(1.0, 0.86, 0.30)
    AQICategory.sensitive -> rgb(1.0, 0.60, 0.25)
    AQICategory.unhealthy -> rgb(0.96, 0.32, 0.32)
    AQICategory.veryUnhealthy -> rgb(0.66, 0.40, 0.86)
    AQICategory.hazardous -> rgb(0.62, 0.20, 0.30)
}

/** AQI (or Canada's AQHI) in a round badge, a colour scale and advice. */
@Composable
fun AirQualityCard(air: AirQuality) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val aqhi = air.aqhi
        val aqhiCat = air.aqhiCategory
        val aqi = air.usAQI
        val cat = air.category
        if (aqhi != null && aqhiCat != null) {
            val display = if (aqhi > 10) "10+" else "${aqhi.rndInt()}"
            Row(verticalAlignment = Alignment.CenterVertically) {
                Ring(display, aqiColor(aqhiCat))
                Spacer(Modifier.width(14.dp))
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(air.aqhiRiskLabel ?: "", style = style(17.sp, FontWeight.SemiBold))
                    Text("AQHI" + (air.aqhiStation?.let { " · $it" } ?: ""), style = style(13.sp, color = White82))
                    air.aqhiTodayMax?.let { peak ->
                        if (peak.rndInt() > aqhi.rndInt()) Text("Up to ${if (peak > 10) "10+" else "${peak.rndInt()}"} later", style = style(13.sp, color = White82))
                    }
                }
            }
            Canvas(Modifier.fillMaxWidth().height(8.dp)) {
                val bands = listOf(AQICategory.good to 3.5, AQICategory.moderate to 6.5, AQICategory.unhealthy to 10.5, AQICategory.veryUnhealthy to 11.0)
                fun frac(v: Double) = min(max((v - 1) / 10, 0.0), 1.0).toFloat()
                var start = 1.0
                for ((c, end) in bands) {
                    val x0 = frac(start) * size.width
                    val w = max(0f, (frac(end) - frac(start)) * size.width - 2.dp.toPx())
                    drawRoundRect(aqiColor(c), Offset(x0, 0f), Size(w, size.height), CornerRadius(size.height / 2))
                    start = end
                }
                marker(frac(min(aqhi, 11.0)) * size.width)
            }
            Text(aqhiCat.advice, style = style(15.sp, color = Color.White.copy(alpha = 0.9f)))
        } else if (aqi != null && cat != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Ring("${aqi.rndInt()}", aqiColor(cat))
                Spacer(Modifier.width(14.dp))
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(cat.label, style = style(17.sp, FontWeight.SemiBold))
                    air.todayMaxAQI?.let { peak ->
                        if (peak.rndInt() > aqi.rndInt() + 4) Text("Up to ${peak.rndInt()} later today", style = style(13.sp, color = White82))
                    }
                }
            }
            Canvas(Modifier.fillMaxWidth().height(8.dp)) {
                val stops = arrayOf(0f to aqiColor(AQICategory.good), 0.15f to aqiColor(AQICategory.good),
                    0.25f to aqiColor(AQICategory.moderate), 0.42f to aqiColor(AQICategory.sensitive),
                    0.58f to aqiColor(AQICategory.unhealthy), 0.8f to aqiColor(AQICategory.veryUnhealthy), 1f to aqiColor(AQICategory.hazardous))
                drawRoundRect(Brush.horizontalGradient(*stops), cornerRadius = CornerRadius(size.height / 2))
                marker((min(max(aqi / 300, 0.0), 1.0) * size.width).toFloat())
            }
            Text(cat.advice, style = style(15.sp, color = Color.White.copy(alpha = 0.9f)))
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            air.pm25?.let { FactChip("PM2.5 ${it.rndInt()}", Icons.Filled.Air) }
            air.pm10?.let { FactChip("PM10 ${it.rndInt()}", Icons.Filled.Air) }
            air.ozone?.let { FactChip("Ozone ${it.rndInt()}", Icons.Filled.WbSunny) }
            air.nitrogenDioxide?.let { FactChip("NO₂ ${it.rndInt()}", Icons.Filled.DirectionsCar) }
        }
        Text(if (air.aqhi != null) "AQHI via Environment Canada. Pollutants via Open-Meteo (Copernicus CAMS), in µg/m³."
             else "US AQI via Open-Meteo (Copernicus CAMS), in µg/m³.",
            style = style(11.sp, color = Color.White.copy(alpha = 0.7f)))
    }
}

@Composable
private fun Ring(text: String, colour: Color) {
    Box(Modifier.size(58.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.14f)).border(4.dp, colour, CircleShape),
        contentAlignment = Alignment.Center) {
        Text(text, style = style(22.sp, FontWeight.Bold))
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.marker(x: Float) {
    val r = (size.height + 4.dp.toPx()) / 2
    drawCircle(Color.White, r, Offset(x, size.height / 2))
    drawCircle(Color.Black.copy(alpha = 0.35f), r, Offset(x, size.height / 2), style = Stroke(1.5.dp.toPx()))
}
