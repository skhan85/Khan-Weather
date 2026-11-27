package com.khanweather.app

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.*
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private data class WeekendPart(
    val label: String,
    val condition: WeatherCondition,
    val isDay: Boolean,
    val temp: Double,
    val feelsLike: Double,
    val pop: Double,
    val precipMm: Double,
    val isSnow: Boolean
)

@Composable
fun WeekendScreen(forecast: Forecast) {
    val zoneId = remember(forecast.timeZoneIdentifier) { ZoneId.of(forecast.timeZoneIdentifier) }
    val weekends = remember(forecast) {
        val out = mutableListOf<List<DailyForecast>>()
        var cur = mutableListOf<DailyForecast>()
        for (d in forecast.displayDaily()) {
            val dow = Instant.ofEpochSecond(d.date.toLong()).atZone(zoneId).dayOfWeek
            if (dow == DayOfWeek.FRIDAY || dow == DayOfWeek.SATURDAY || dow == DayOfWeek.SUNDAY) {
                if (dow == DayOfWeek.FRIDAY && cur.isNotEmpty()) {
                    out += cur; cur = mutableListOf()
                }
                cur += d
                if (dow == DayOfWeek.SUNDAY) {
                    out += cur; cur = mutableListOf()
                }
            } else if (cur.isNotEmpty()) {
                out += cur; cur = mutableListOf()
            }
        }
        if (cur.isNotEmpty()) out += cur
        out
    }

    var tab by remember { mutableIntStateOf(0) }
    val activeDays = if (tab < weekends.size) weekends[tab] else emptyList()
    var expandedDate by remember(tab) { mutableStateOf(activeDays.firstOrNull()?.date) }

    fun dayName(epoch: Double): String =
        DateTimeFormatter.ofPattern("EEE", Locale.US).format(Instant.ofEpochSecond(epoch.toLong()).atZone(zoneId))

    fun monthDay(epoch: Double): String =
        DateTimeFormatter.ofPattern("MMM d", Locale.US).format(Instant.ofEpochSecond(epoch.toLong()).atZone(zoneId))

    fun summaryText(days: List<DailyForecast>): String {
        if (days.isEmpty()) return "Next weekend is just beyond the current 10-day forecast window."
        val parts = days.map { d ->
            val name = dayName(d.date)
            val cond = d.condition.label.lowercase()
            val hi = WeatherFormat.temperature(d.high)
            val pop = (d.precipitationProbability ?: 0.0).roundToInt()
            if (d.condition.isPrecipitation || pop >= 50) "$name looks wet ($cond, high $hi, $pop% chance)"
            else "$name brings $cond skies near $hi"
        }
        return when (parts.size) {
            1 -> "${parts[0]}."
            2 -> "${parts[0]}, while ${parts[1]}."
            else -> "${parts[0]}. ${parts[1]}, and ${parts[2]}."
        }
    }

    fun partsFor(day: DailyForecast): List<WeekendPart> {
        val hrs = forecast.displayHours(day)
        if (hrs.isEmpty()) return emptyList()
        val slices = listOf(
            Triple("Morn", 6..11, true),
            Triple("Aft", 12..17, true),
            Triple("Eve", 18..23, false),
            Triple("Night", 0..5, false)
        )
        return slices.mapNotNull { (label, range, isDay) ->
            val sub = hrs.filter { Instant.ofEpochSecond(it.time.toLong()).atZone(zoneId).hour in range }
            if (sub.isEmpty()) return@mapNotNull null
            val temp = if (isDay) sub.maxOf { it.temperature } else sub.minOf { it.temperature }
            val feels = if (isDay) sub.maxOf { it.feelsLike ?: it.temperature } else sub.minOf { it.feelsLike ?: it.temperature }
            val pop = sub.mapNotNull { it.precipitationProbability }.maxOrNull() ?: 0.0
            val rainSum = sub.sumOf { it.rain ?: 0.0 }
            val snowSum = sub.sumOf { it.snowfall ?: 0.0 }
            val precipSum = max(sub.sumOf { it.precipitation ?: 0.0 }, rainSum + snowSum * 0.7)
            val isSnow = snowSum > rainSum && snowSum >= 0.1
            var cond = sub.firstOrNull { it.condition.isWetOrStorm }?.condition ?: sub[sub.size / 2].condition
            if (!cond.isWetOrStorm && pop >= 50.0) cond = if (isSnow) WeatherCondition.SNOW else WeatherCondition.RAIN
            WeekendPart(label, cond, isDay, temp, feels, pop, precipSum, isSnow)
        }
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        // Segmented toggle
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.08f)).padding(4.dp)
        ) {
            listOf(0 to "This weekend", 1 to "Next weekend").forEach { (idx, title) ->
                val selected = tab == idx
                Box(
                    Modifier.weight(1f).clip(RoundedCornerShape(50))
                        .background(if (selected) Color.White.copy(alpha = 0.16f) else Color.Transparent)
                        .clickable { tab = idx }
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        title,
                        style = style(14.sp, FontWeight.SemiBold, if (selected) rgb(1.0, 0.85, 0.28) else Color.White.copy(alpha = 0.85f))
                    )
                }
            }
        }

        // Summary card
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.10f)).padding(14.dp)) {
            Text(summaryText(activeDays), style = style(14.sp, color = Color.White.copy(alpha = 0.92f)))
        }

        if (activeDays.isNotEmpty()) {
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.08f)).padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.CalendarToday, null, tint = Color.White, modifier = Modifier.size(16.dp))
                    Text("Weekend Forecast", style = style(16.sp, FontWeight.SemiBold, Color.White))
                }
                for (day in activeDays) {
                    val isExpanded = expandedDate == day.date
                    val dayParts = remember(day) { partsFor(day) }
                    val totalMm = (day.rainSum ?: 0.0) + (day.snowfallSum ?: 0.0)
                    val pop = (day.precipitationProbability ?: 0.0).roundToInt()

                    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color.White.copy(alpha = 0.08f))) {
                        Row(
                            Modifier.fillMaxWidth().clickable { expandedDate = if (isExpanded) null else day.date }.padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Column(Modifier.width(52.dp)) {
                                Text(dayName(day.date), style = style(14.sp, FontWeight.SemiBold, Color.White))
                                Text(monthDay(day.date), style = style(11.sp, color = Color.White.copy(alpha = 0.68f)))
                            }
                            IconBadge(day.condition, true, 32.dp)
                            Text(WeatherFormat.temperature(day.high), style = style(18.sp, FontWeight.SemiBold, Color.White))
                            Text(WeatherFormat.temperature(day.low), style = style(14.sp, color = Color.White.copy(alpha = 0.68f)))
                            Spacer(Modifier.weight(1f))
                            Column(horizontalAlignment = Alignment.End) {
                                if (pop >= 20) Text("$pop%", style = style(12.sp, FontWeight.SemiBold, rgb(0.45, 0.80, 1.0)))
                                if (totalMm >= 0.5) Text("${totalMm.roundToInt()} mm", style = style(10.sp, color = Color.White.copy(alpha = 0.75f)))
                            }
                            Icon(
                                if (isExpanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                                null, tint = Color.White.copy(alpha = 0.55f), modifier = Modifier.size(18.dp)
                            )
                        }

                        if (isExpanded) {
                            if (dayParts.isNotEmpty()) {
                                val maxMm = max(dayParts.maxOf { it.precipMm }, 2.0)
                                Row(
                                    Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, bottom = 8.dp).clip(RoundedCornerShape(12.dp)),
                                    horizontalArrangement = Arrangement.spacedBy(1.dp)
                                ) {
                                    for (part in dayParts) {
                                        val fillFrac = min(1.0, part.precipMm / maxMm)
                                        Column(
                                            Modifier.weight(1f)
                                                .background(if (part.isDay) Color.White.copy(alpha = 0.05f) else Color.Black.copy(alpha = 0.14f))
                                                .padding(top = 10.dp),
                                            horizontalAlignment = Alignment.CenterHorizontally,
                                            verticalArrangement = Arrangement.spacedBy(5.dp)
                                        ) {
                                            Text(part.label, style = style(11.sp, FontWeight.Medium, Color.White.copy(alpha = 0.75f)))
                                            IconBadge(part.condition, part.isDay, 32.dp)
                                            Text(WeatherFormat.temperature(part.temp), style = style(17.sp, FontWeight.Bold, Color.White))
                                            Text("Feels ${WeatherFormat.temperature(part.feelsLike)}", style = style(10.sp, color = Color.White.copy(alpha = 0.68f)))
                                            if (part.pop >= 15.0) {
                                                Text("${part.pop.roundToInt()}%", style = style(11.sp, FontWeight.SemiBold, rgb(0.45, 0.80, 1.0)))
                                            } else {
                                                Text("–", style = style(11.sp, color = Color.White.copy(alpha = 0.4f)))
                                            }
                                            Text(
                                                if (part.precipMm >= 0.1) String.format(Locale.US, "%.1f mm", part.precipMm) else "–",
                                                style = style(10.sp, color = Color.White.copy(alpha = 0.75f))
                                            )
                                            Box(Modifier.fillMaxWidth().height(22.dp), contentAlignment = Alignment.BottomCenter) {
                                                if (part.precipMm >= 0.1) {
                                                    val barColor = (if (part.isSnow) Color.White else rgb(0.35, 0.72, 1.0)).copy(alpha = 0.45f)
                                                    Box(Modifier.fillMaxWidth().height(max(5.0, 22.0 * fillFrac).dp).background(barColor))
                                                }
                                            }
                                        }
                                    }
                                }
                            } else {
                                Text(
                                    "${day.condition.label} · High ${WeatherFormat.temperature(day.high)}, Low ${WeatherFormat.temperature(day.low)}",
                                    style = style(12.sp, color = Color.White.copy(alpha = 0.75f)),
                                    modifier = Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
