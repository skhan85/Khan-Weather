package com.khanweather.app

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.*
import kotlin.math.max
import kotlin.math.min

val TextShadow = Shadow(Color.Black.copy(alpha = 0.3f), Offset(0f, 2f), 4f)

fun style(size: TextUnit, weight: FontWeight = FontWeight.Normal, color: Color = Color.White, shadow: Boolean = false) =
    TextStyle(fontSize = size, fontWeight = weight, color = color, shadow = if (shadow) TextShadow else null)

/** The sky gradient behind every screen, following the weather and day or night. */
@Composable
fun SkyBackground(condition: WeatherCondition, isDay: Boolean, modifier: Modifier = Modifier) {
    val sky = Sky.of(condition, isDay)
    val top by animateColorAsState(sky.top, tween(800), label = "top")
    val bottom by animateColorAsState(sky.bottom, tween(800), label = "bottom")
    val stars = remember {
        var seed = 0x9E3779B97F4A7C15uL
        fun next(): Double {
            seed = seed * 6364136223846793005uL + 1442695040888963407uL
            return (seed shr 33).toDouble() / (1L shl 31).toDouble()
        }
        List(60) { listOf(next(), next(), 0.6 + next() * 1.1, 0.25 + next() * 0.5) }
    }
    Canvas(modifier.fillMaxSize()) {
        drawRect(Brush.verticalGradient(listOf(top, bottom)))
        when (sky.decoration) {
            Sky.Decoration.sunGlow -> drawRect(Brush.radialGradient(
                listOf(Color(1f, 0.93f, 0.7f, 0.45f), Color.Transparent),
                center = Offset(size.width * 0.85f, size.height * 0.02f), radius = 320.dp.toPx()))
            Sky.Decoration.stars -> for (s in stars) {
                drawCircle(Color.White.copy(alpha = s[3].toFloat()), radius = s[2].toFloat() * density,
                    center = Offset((s[0] * size.width).toFloat(), (s[1] * size.height * 0.5).toFloat()))
            }
            Sky.Decoration.haze -> drawRect(Brush.verticalGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.12f))))
            Sky.Decoration.plain -> {}
        }
    }
}

/** A weather symbol, drawn in code. */
@Composable
fun ConditionIcon(condition: WeatherCondition, isDay: Boolean = true, size: Dp, heavy: Boolean = false) {
    Canvas(Modifier.size(size)) {
        drawIntoCanvas { WeatherIcons.draw(it.nativeCanvas, this.size.minDimension, condition, isDay, heavy) }
    }
}

/** A weather icon sitting in a soft round badge. */
@Composable
fun IconBadge(condition: WeatherCondition, isDay: Boolean = true, size: Dp = 36.dp, heavy: Boolean = false) {
    val bg = if (condition.isPrecipitation) Color(0xFF0E1B2E).copy(alpha = 0.42f) else Color.White.copy(alpha = 0.14f)
    Box(
        Modifier.size(size).clip(CircleShape).background(bg)
            .border(0.5.dp, Color.White.copy(alpha = 0.22f), CircleShape),
        contentAlignment = Alignment.Center,
    ) { ConditionIcon(condition, isDay, size * 0.72f, heavy) }
}

/** Section title that reads well on the sky. */
@Composable
fun SectionHeader(title: String, icon: ImageVector) {
    Row(Modifier.padding(start = 20.dp, bottom = 6.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Gold, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(title, style = style(15.sp, FontWeight.Bold, Color.White.copy(alpha = 0.95f), shadow = true))
    }
}

/** Translucent "glass" card used on the sky screens, like an inset list section. */
@Composable
fun GlassCard(modifier: Modifier = Modifier, padding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
              content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.10f)).background(Color.Black.copy(alpha = 0.20f))
            .padding(padding),
        content = content,
    )
}

@Composable
fun Section(title: String?, icon: ImageVector?, padding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
            content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(bottom = 14.dp)) {
        if (title != null && icon != null) SectionHeader(title, icon)
        GlassCard(padding = padding, content = content)
    }
}

@Composable
fun RowDivider() = HorizontalDivider(color = Color.White.copy(alpha = 0.15f), thickness = 0.5.dp)

/** A row that opens another screen, with a chevron. */
@Composable
fun LinkRow(onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, content = content)
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Color.White.copy(alpha = 0.5f))
    }
}

/** Rounded "chip" for a small fact, e.g. humidity. */
@Composable
fun FactChip(text: String, icon: ImageVector) {
    Row(Modifier.height(32.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.14f)).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Gold, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(5.dp))
        Text(text, style = style(15.sp, FontWeight.SemiBold), maxLines = 1)
    }
}

/** Gold capsule label such as "NOW". */
@Composable
fun GoldPill(text: String, size: TextUnit = 12.sp) {
    Text(text, style = style(size, FontWeight.ExtraBold, Color.Black.copy(alpha = 0.8f)).copy(letterSpacing = 1.5.sp),
        modifier = Modifier.clip(RoundedCornerShape(50)).background(Gold).padding(horizontal = 8.dp, vertical = 2.dp))
}

/** "💧 40%": a chance of precipitation that says what it's a chance of. Hidden under 10%. */
@Composable
fun PrecipChance(probability: Double?, kind: PrecipitationKind, size: TextUnit = 12.sp, showsIcon: Boolean = true) {
    if (probability == null || probability < 10) return
    val colour = if (kind == PrecipitationKind.snow) ChanceSnow else ChanceBlue
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (showsIcon) {
            Icon(if (kind == PrecipitationKind.snow) Icons.Filled.AcUnit else Icons.Filled.WaterDrop, null,
                tint = colour, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(2.dp))
        }
        Text(WeatherFormat.percent(probability), style = style(size, FontWeight.SemiBold, colour))
    }
}

/** A day's high-to-low span drawn against the whole week's range (high on the left). */
@Composable
fun TemperatureRangeBar(low: Double, high: Double, weekLow: Double, weekHigh: Double, current: Double?, modifier: Modifier) {
    Canvas(modifier.height(8.dp)) {
        val span = max(weekHigh - weekLow, 1.0)
        val w = size.width
        val h = size.height
        val start = ((weekHigh - high) / span * w).toFloat()
        val end = ((weekHigh - low) / span * w).toFloat()
        val barWidth = max(end - start, h)
        val x0 = min(start, w - barWidth)
        drawRoundRect(Color.White.copy(alpha = 0.18f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(h / 2))
        drawRoundRect(TemperatureColor.gradientAt(low, high, x0, x0 + barWidth), topLeft = Offset(x0, 0f),
            size = androidx.compose.ui.geometry.Size(barWidth, h), cornerRadius = androidx.compose.ui.geometry.CornerRadius(h / 2))
        if (current != null) {
            val x = min(max(((weekHigh - current) / span * w).toFloat(), 0f), w)
            val r = (h + 3.dp.toPx()) / 2
            drawCircle(Color.White, r, Offset(x, h / 2))
            drawCircle(Color.Black.copy(alpha = 0.35f), r, Offset(x, h / 2), style = androidx.compose.ui.graphics.drawscope.Stroke(1.5.dp.toPx()))
        }
    }
}

fun TemperatureColor.gradientAt(low: Double, high: Double, startX: Float, endX: Float): Brush =
    Brush.horizontalGradient((0..4).map { color(high - (high - low) * it / 4.0) }, startX = startX, endX = endX)

/** Three small bars: all gold when the models agree on the day, one when they don't. */
@Composable
fun ConfidenceMark(confidence: ForecastConfidence) {
    val filled = when (confidence) { ForecastConfidence.sure -> 3; ForecastConfidence.fair -> 2; ForecastConfidence.unsure -> 1 }
    Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        repeat(3) { i ->
            Box(Modifier.size(7.dp, 4.dp).clip(RoundedCornerShape(50)).background(if (i < filled) Gold else Color.White.copy(alpha = 0.25f)))
        }
    }
}

/** The big rounded card behind the Now card and detail heroes. */
fun Modifier.heroCard(): Modifier = this.padding(horizontal = 16.dp).fillMaxWidth()
    .clip(RoundedCornerShape(28.dp))
    .background(Brush.linearGradient(listOf(Color.White.copy(alpha = 0.22f), Color.White.copy(alpha = 0.06f))))
    .border(1.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(28.dp))
    .padding(18.dp)
