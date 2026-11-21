package com.khanweather.app

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.*

/**
 * One alert as a card: colour-coded headline ("Yellow advisory - fog"), the area, a three-line
 * preview with the stock Environment Canada lines removed, and "1 hour ago · source". Tap to
 * read the rest. The card has its own dark surface so the text stays readable on any sky; the
 * risk colour is only an accent (edge stripe, icon and headline), never the background.
 */
@Composable
fun AlertCard(alert: WeatherAlert, zone: String, startExpanded: Boolean = false) {
    var expanded by remember(alert.id) { mutableStateOf(startExpanded) }
    val colour = alertColour(alert)
    val accent = alertAccent(alert)
    val context = LocalContext.current
    Column(
        Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(20.dp))
            .background(Color(0.07f, 0.08f, 0.11f, 0.90f))
            .background(colour.copy(alpha = 0.10f))
            .drawBehind { drawRect(colour, size = Size(6.dp.toPx(), size.height)) }
            .clickable { expanded = !expanded }
            .animateContentSize()
            .padding(start = 22.dp, end = 16.dp, top = 16.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(alert.headline, style = style(20.sp, FontWeight.Bold, accent))
                subtitle(alert, zone)?.let { Text(it, style = style(15.sp, color = Color.White.copy(alpha = 0.8f))) }
            }
            Spacer(Modifier.width(6.dp))
            Icon(when (alert.kind) {
                WeatherAlert.Kind.warning -> Icons.Filled.Warning
                WeatherAlert.Kind.watch -> Icons.Filled.Visibility
                WeatherAlert.Kind.advisory -> Icons.Filled.Error
                else -> Icons.Filled.Info
            }, null, tint = colour, modifier = Modifier.size(26.dp))
        }
        if (expanded) {
            for (p in alert.readableParagraphs) Text(p, style = style(16.sp))
        } else {
            Text(alert.summary, style = style(16.sp), maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(footer(alert), style = style(13.sp, color = Color.White.copy(alpha = 0.75f)), modifier = Modifier.weight(1f),
                maxLines = if (expanded) 4 else 1, overflow = TextOverflow.Ellipsis)
            Icon(if (expanded) Icons.Filled.KeyboardArrowUp else Icons.AutoMirrored.Filled.KeyboardArrowRight, null,
                tint = Color.White.copy(alpha = 0.75f), modifier = Modifier.size(18.dp))
        }
        val issued = alert.issuedAt
        if (expanded && issued != null) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Issued ${TimeText.weekdayTime(issued, zone)}", style = style(13.sp, color = Color.White.copy(alpha = 0.75f)))
                if (alert.source.contains("Canada")) {
                    Text("Open on weather.gc.ca", style = style(13.sp, FontWeight.SemiBold, accent),
                        modifier = Modifier.clickable {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://weather.gc.ca/warnings/index_e.html")))
                        })
                }
            }
        }
    }
}

private fun subtitle(a: WeatherAlert, zone: String): String? {
    val parts = mutableListOf<String>()
    a.area?.let { parts += it }
    a.eventEndsAt?.let { if (it > nowEpoch()) parts += "until ${TimeText.weekdayTime(it, zone)}" }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

/** "1 hour ago · Environment and Climate Change Canada". */
private fun footer(a: WeatherAlert): String {
    val issued = a.issuedAt ?: return a.source
    val s = nowEpoch() - issued
    val ago = when {
        s < 60 -> "Just now"
        s < 3600 -> plural((s / 60).toInt(), "minute") + " ago"
        s < 86400 -> plural((s / 3600).toInt(), "hour") + " ago"
        else -> plural((s / 86400).toInt(), "day") + " ago"
    }
    return "$ago · ${a.source}"
}

private fun plural(n: Int, word: String) = if (n == 1) "1 $word" else "$n ${word}s"

fun alertColour(a: WeatherAlert): Color = when (a.risk) {
    WeatherAlert.Risk.red -> Color(0.92f, 0.2f, 0.2f)
    WeatherAlert.Risk.orange -> Color(1.0f, 0.55f, 0.1f)
    WeatherAlert.Risk.yellow -> Color(1.0f, 0.82f, 0.1f)
    WeatherAlert.Risk.unknown -> if (a.kind == WeatherAlert.Kind.warning) Color(1.0f, 0.55f, 0.1f) else Color.Gray
}

fun alertAccent(a: WeatherAlert): Color = when (a.risk) {
    WeatherAlert.Risk.red -> Color(1.0f, 0.48f, 0.45f)
    WeatherAlert.Risk.orange -> Color(1.0f, 0.66f, 0.3f)
    WeatherAlert.Risk.yellow -> Color(1.0f, 0.85f, 0.3f)
    WeatherAlert.Risk.unknown -> if (a.kind == WeatherAlert.Kind.warning) Color(1.0f, 0.66f, 0.3f) else Color.White
}
