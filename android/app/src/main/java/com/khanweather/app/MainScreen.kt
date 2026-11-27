package com.khanweather.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.*
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** Everything the main screen shows, in the iPhone app's order. */
@Composable
fun ForecastList(
    forecast: Forecast,
    alerts: List<WeatherAlert>,
    airQuality: AirQuality?,
    normals: ClimateNormals?,
    placeName: String?,
    isSavedPlace: Boolean,
    usingFallbackLocation: Boolean,
    nav: (Screen) -> Unit,
) {
    val zone = forecast.timeZoneIdentifier
    val days = forecast.displayDaily()
    val today = forecast.displayDay()
    val weekLow = days.minOfOrNull { it.low } ?: 0.0
    val weekHigh = days.maxOfOrNull { it.high } ?: 0.0
    val localNormals = normals?.takeIf { it.covers(forecast.location) }
    fun normalHigh(d: DailyForecast) = localNormals?.normal(d.date, zone)?.first
    val vsNormal = today?.let { t -> normalHigh(t)?.let { n -> NormalComparison.shortText(t.high, n) to NormalComparison.trend(t.high, n) } }
    val vsYesterday = forecast.changeSinceYesterday()?.let { YesterdayComparison.shortText(it) to YesterdayComparison.trend(it) }
    val hourText: (Epoch) -> String = { TimeText.hour(it, zone) }

    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(top = 4.dp, bottom = 24.dp)) {
        if (usingFallbackLocation) {
            Section(null, null) {
                NoteRow(Icons.Filled.LocationOff, "Location is off, so this shows Toronto. Allow location for Khan Weather for weather where you are.")
            }
        }
        if (nowEpoch() - forecast.fetchedAt > 45 * 60) {
            Section(null, null) {
                NoteRow(Icons.Filled.History, "Couldn't refresh. This is the forecast from ${TimeText.time(forecast.fetchedAt, zone)}; pull down to try again.")
            }
        }
        var hazards by remember(forecast.fetchedAt) { mutableStateOf<WeatherLoader.RelayHazards?>(null) }
        LaunchedEffect(forecast.fetchedAt) {
            val storms = forecast.radar?.isPrecipitating == true || forecast.nowcast() != null
            val cold = forecast.current.temperature <= 3.0
            hazards = WeatherLoader.relayHazards(forecast.location, storms = storms, cold = cold)
        }
        for (a in alerts) {
            AlertCard(a, zone)
            Spacer(Modifier.height(8.dp))
        }
        for (b in hazards?.banners().orEmpty()) {
            val bIcon = when (b.kind) {
                "lightning" -> Icons.Filled.Bolt
                "hail" -> Icons.Filled.Grain
                else -> Icons.Filled.DirectionsCar
            }
            Section(null, null) { LabelLine(bIcon, b.text) }
        }
        NowCard(forecast, placeName, isSavedPlace, today,
            listOfNotNull(Outlook.text(forecast, hourText = hourText), Outlook.dryWindow(forecast, hourText = hourText)).joinToString("\n").ifEmpty { null },
            WhatToWear.tip(forecast.current, forecast.upcomingHours(count = 13).drop(1), hourText = hourText),
            vsNormal, vsYesterday)
        Spacer(Modifier.height(14.dp))

        forecast.nowcast()?.let { n ->
            Section("Next 2 hours", Icons.Filled.Umbrella) { NextTwoHours(n, forecast.nowcastSlots()) }
        }
        val parts = forecast.dayParts()
        if (parts.size == 4) Section("Today and tonight", Icons.Filled.WbTwilight, PaddingValues(10.dp)) { DayPartsRow(parts) }

        val count = Prefs.hourlyCount
        Section("Next $count hours", Icons.Filled.Schedule, PaddingValues(vertical = 8.dp)) {
            HourlyCurve(forecast.hoursStartingNow(count = count), zone, firstIsNow = true) { nav(Screen.Hour(it, zone)) }
        }

        // Live radar loop. Environment Canada in Canada and the US, RainViewer elsewhere.
        Section("Radar", Icons.Filled.Radar, PaddingValues(horizontal = 12.dp, vertical = 12.dp)) {
            RadarCard(forecast.location) { nav(Screen.Radar) }
        }

        Box(

            Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp))

                .background(Color.White.copy(alpha = 0.10f))

                .clickable { nav(Screen.Weekend) }

                .padding(horizontal = 14.dp, vertical = 12.dp)

        ) {

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {

                Icon(Icons.Filled.WbSunny, null, tint = rgb(1.0, 0.82, 0.28), modifier = Modifier.size(20.dp))

                Column(Modifier.weight(1f)) {

                    Text("Weekend forecast", style = style(14.sp, FontWeight.SemiBold, Color.White))

                    Text("Fri–Sun · Morn / Aft / Eve / Night", style = style(12.sp, color = Color.White.copy(alpha = 0.68f)))

                }

                Icon(Icons.Filled.ChevronRight, null, tint = Color.White.copy(alpha = 0.55f))

            }

        }

        Section("${forecast.daily.size}-day forecast", Icons.Filled.CalendarMonth, PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
            days.forEachIndexed { i, day ->
                LinkRow({ nav(Screen.Day(day, i)) }) {
                    DailyRow(day, i == 0, zone, weekLow, weekHigh, if (i == 0) forecast.current.temperature else null,
                        normalHigh(day)?.let { NormalComparison.trend(day.high, it) })
                }
                if (i < days.lastIndex) RowDivider()
            }
        }

        if (Prefs.showDetails) Section("Today", Icons.Filled.WbSunny, PaddingValues(10.dp)) { TodayDetails(forecast) }

        if (Prefs.showAirQuality && airQuality != null && (airQuality.usAQI != null || airQuality.aqhi != null)) {
            Section("Air quality", Icons.Filled.Air) { AirQualityCard(airQuality) }
        }

        Section(null, null, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
            LinkRow({ nav(Screen.Sources) }) {
                Column {
                    Text("Sources: " + Credits.shortNames(forecast, alerts).joinToString(", "), style = style(13.sp))
                    Text("Updated ${TimeText.time(forecast.fetchedAt, java.time.ZoneId.systemDefault().id)}", style = style(13.sp, color = White82))
                }
            }
        }
    }
}

/** Environment Canada's mosaic covers Canada and the northern US. */
fun radarCovers(c: Coordinate) = c.latitude in 35.0..75.0 && c.longitude in -145.0..-50.0

@Composable
fun NoteRow(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(text, style = style(13.sp))
    }
}

@Composable
fun NowCard(
    forecast: Forecast, placeName: String?, isSavedPlace: Boolean, today: DailyForecast?,
    outlook: String?, wear: String?, vsNormal: Pair<String, Int>?, vsYesterday: Pair<String, Int>?,
) {
    val current = forecast.current
    val observation = forecast.observation
    val feelsFirst = Prefs.feelsLikeFirst
    val feelsText = if (feelsFirst) "${WeatherFormat.feelsLikeLabel(current.feelsLikeKind)}. Actual ${WeatherFormat.temperature(current.temperature)}"
    else "${WeatherFormat.feelsLikeLabel(current.feelsLikeKind)} ${WeatherFormat.temperature(current.feelsLike)}"
    Column(Modifier.heroCard(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (placeName != null) {
                Icon(if (isSavedPlace) Icons.Filled.Place else Icons.Filled.NearMe, null, tint = Color.White, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(6.dp))
                Text(placeName, style = style(20.sp, FontWeight.Bold, shadow = true), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f))
            } else Spacer(Modifier.weight(1f))
            GoldPill("NOW")
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconBadge(current.condition, current.isDay, 96.dp)
            Spacer(Modifier.width(16.dp))
            Column {
                Text(WeatherFormat.temperature(if (feelsFirst) current.feelsLike else current.temperature),
                    style = style(76.sp, FontWeight.Bold, shadow = true).copy(lineHeight = 80.sp), maxLines = 1)
                Text(observation?.conditionText ?: current.condition.description, style = style(20.sp, FontWeight.SemiBold, shadow = true))
                Text(feelsText, style = style(17.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.9f), shadow = true))
            }
        }
        if (outlook != null) {
            Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.18f))
                .drawBehind {
                    drawRoundRect(Gold, Offset(0f, 6.dp.toPx()), Size(4.dp.toPx(), size.height - 12.dp.toPx()), CornerRadius(2.dp.toPx()))
                }.padding(horizontal = 12.dp, vertical = 8.dp)) {
                Text(outlook, style = style(17.sp, FontWeight.SemiBold, shadow = true))
            }
        }
        if (wear != null) LabelLine(Icons.Filled.Checkroom, wear)
        val comparisons = listOfNotNull(vsNormal, vsYesterday)
        comparisons.firstOrNull()?.let { first ->
            LabelLine(if (first.second > 0) Icons.Filled.WbSunny else if (first.second < 0) Icons.Filled.AcUnit else Icons.Filled.Thermostat,
                comparisons.joinToString(" · ") { it.first })
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (today != null) FactChip("${WeatherFormat.temperature(today.high)} / ${WeatherFormat.temperature(today.low)}", Icons.Filled.Thermostat)
            current.humidity?.let { FactChip(WeatherFormat.percent(it), Icons.Filled.WaterDrop) }
            current.windSpeed?.let { FactChip(WeatherFormat.wind(it), Icons.Filled.Air) }
        }
        val zone = forecast.timeZoneIdentifier
        val caption = when {
            observation != null && observation.isLocal ->
                "Temperature from ${WeatherFormat.readingSource(observation)}, ${TimeText.time(observation.observedAt, zone)}. Sky from ${forecast.skySource ?: "the forecast"}."
            observation != null -> "Sky from ${forecast.skySource ?: "the forecast"}. Temperature is the forecast for your spot."
            else -> "Model estimate (no nearby station)"
        }
        Text(caption, style = style(13.sp, color = Color.White.copy(alpha = 0.88f), shadow = true))
    }
}

@Composable
fun LabelLine(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = Gold, modifier = Modifier.size(18.dp).padding(top = 1.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, style = style(15.sp, FontWeight.SemiBold, shadow = true))
    }
}

/** One day in the list: weekday, icon, chance of rain or snow, and the high-to-low bar. */
@Composable
fun DailyRow(day: DailyForecast, isToday: Boolean, zone: String, weekLow: Double, weekHigh: Double, current: Double?, normalTrend: Int?) {
    Row(Modifier.padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.width(62.dp)) {
            Text(if (isToday) "Today" else TimeText.weekdayShort(day.date, zone),
                style = style(17.sp, FontWeight.Bold, if (isToday) Gold else Color.White))
            WeatherFormat.precipitationTotals(day.rainSum, day.snowfallSum)?.let {
                Text(it, style = style(11.sp, color = White82), maxLines = 1)
            }
            day.confidence?.let { Spacer(Modifier.height(2.dp)); ConfidenceMark(it) }
        }
        Spacer(Modifier.width(6.dp))
        Column(Modifier.width(40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            IconBadge(day.condition, true, 34.dp, heavy = (day.rainSum ?: 0.0) >= 12.0, mixed = day.isMixedPrecipitation)
            PrecipChance(day.precipitationProbability, day.precipitationKind, 11.sp, showsIcon = false)
        }
        Spacer(Modifier.width(6.dp))
        Row(Modifier.width(46.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            if (normalTrend != null && normalTrend != 0) {
                Icon(if (normalTrend > 0) Icons.Filled.ArrowUpward else Icons.Filled.ArrowDownward, null,
                    tint = if (normalTrend > 0) Gold else ColdBlue, modifier = Modifier.size(12.dp))
            }
            Text(WeatherFormat.temperature(day.high), style = style(17.sp, FontWeight.SemiBold))
        }
        Spacer(Modifier.width(8.dp))
        TemperatureRangeBar(day.low, day.high, weekLow, weekHigh, current, Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Text(WeatherFormat.temperature(day.low), style = style(17.sp, FontWeight.Medium, White82), modifier = Modifier.width(36.dp))
    }
}

/** Morning, afternoon, evening and overnight. */
@Composable
fun DayPartsRow(parts: List<DayPart>) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        for (p in parts) {
            Column(Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f)).padding(vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(p.kind.label, style = style(12.sp, FontWeight.Bold, Color.White.copy(alpha = 0.88f)), maxLines = 1)
                IconBadge(p.condition, p.isDay, 38.dp)
                Text(WeatherFormat.temperature(p.temperature), style = style(22.sp, FontWeight.Bold))
                p.feelsLike?.let { Text("Feels ${WeatherFormat.temperature(it)}", style = style(12.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.85f)), maxLines = 1) }
                PrecipChance(p.precipitationProbability, p.precipitationKind, 11.sp, showsIcon = true)
            }
        }
    }
}

/** Next two hours in 15-minute bars. */
@Composable
fun NextTwoHours(nowcast: Nowcast, slots: List<PrecipitationSlot>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val nowcastIcon = when (nowcast.kind) {
            Nowcast.Kind.snow -> Icons.Filled.AcUnit
            Nowcast.Kind.mixed -> Icons.Filled.Grain
            Nowcast.Kind.rain -> Icons.Filled.Umbrella
        }
        LabelLine(nowcastIcon, nowcast.text)
        val midEpoch = if (slots.size > 4) slots[slots.size / 2].time else nowEpoch() + 3600.0
        val endEpoch = (slots.lastOrNull()?.time?.plus(900.0)) ?: (nowEpoch() + 7200.0)
        fun tickLabel(epoch: Double): String {
            val zdt = java.time.Instant.ofEpochSecond(epoch.toLong()).atZone(java.time.ZoneId.systemDefault())
            val fmt = if (zdt.minute == 0) "h a" else "h:mm a"
            return java.time.format.DateTimeFormatter.ofPattern(fmt, java.util.Locale.US).format(zdt).lowercase()
        }
        Row(Modifier.fillMaxWidth().height(92.dp), verticalAlignment = Alignment.Bottom) {
            Column(Modifier.width(50.dp).fillMaxHeight().padding(end = 6.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.SpaceBetween) {
                Text("Heavy", style = style(10.sp, color = Color.White.copy(alpha = 0.62f)))
                Text("Moderate", style = style(10.sp, color = Color.White.copy(alpha = 0.62f)))
                Text("Light", style = style(10.sp, color = Color.White.copy(alpha = 0.62f)))
                Spacer(Modifier.height(10.dp))
            }
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomStart) {
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.SpaceBetween) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.14f)))
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.14f)))
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.14f)))
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.24f)))
                }
                Row(Modifier.fillMaxWidth().fillMaxHeight(), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.Bottom) {
                    for (s in slots) {
                        val h = if (!s.isWet) 3.0 else 14 + 74 * min(sqrt(max(s.precipitation, s.snowfall) / 1.0), 1.0)
                        val colour = when {
                            !s.isWet -> Color.White.copy(alpha = 0.25f)
                            s.snowfall > 0 && s.rain < PrecipitationSlot.wetThreshold -> Color.White
                            s.snowfall > 0 -> rgb(0.78, 0.72, 1.0)
                            else -> rgb(0.45, 0.75, 1.0)
                        }
                        Box(Modifier.weight(1f).height(h.dp).clip(RoundedCornerShape(topStart = 5.dp, topEnd = 5.dp, bottomStart = 2.dp, bottomEnd = 2.dp)).background(colour))
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(start = 50.dp)) {
            Text("Now", style = style(11.sp, FontWeight.SemiBold, White82)); Spacer(Modifier.weight(1f))
            Text(tickLabel(midEpoch), style = style(11.sp, FontWeight.SemiBold, White82)); Spacer(Modifier.weight(1f))
            Text(tickLabel(endEpoch), style = style(11.sp, FontWeight.SemiBold, White82))
        }
        Row(Modifier.padding(start = 50.dp, top = 2.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(14.dp).height(6.dp).clip(RoundedCornerShape(50)).background(rgb(0.45, 0.75, 1.0)))
                Text("Rain", style = style(11.sp, color = Color.White.copy(alpha = 0.75f)))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(14.dp).height(6.dp).clip(RoundedCornerShape(50)).background(Color.White))
                Text("Snow", style = style(11.sp, color = Color.White.copy(alpha = 0.75f)))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(14.dp).height(6.dp).clip(RoundedCornerShape(50)).background(rgb(0.78, 0.72, 1.0)))
                Text("Mixed", style = style(11.sp, color = Color.White.copy(alpha = 0.75f)))
            }
        }
    }
}

private data class Tile(val title: String, val value: String, val icon: androidx.compose.ui.graphics.vector.ImageVector,
                        val note: String = "", val trend: Int? = null)

/** Sun arc, moon and a grid of today's extra numbers. */
@Composable
fun TodayDetails(forecast: Forecast) {
    val zone = forecast.timeZoneIdentifier
    val now = forecast.current
    val hour = forecast.hour()
    val day = forecast.day()
    val tiles = mutableListOf<Tile>()
    val restOfToday = forecast.upcomingHours(count = 24).filter { forecast.cal.isSameDay(it.time, nowEpoch()) }
    WeatherFormat.uvLevel(hour?.uvIndex)?.let {
        tiles += Tile("UV index", it, Icons.Filled.WbSunny, DetailNotes.uv(restOfToday) { t -> TimeText.hour(t, zone) })
    }
    (now.windGusts ?: hour?.windGusts)?.let { gusts ->
        var text = WeatherFormat.wind(gusts)
        WeatherFormat.compass(now.windDirection)?.let { text = "$it, $text" }
        tiles += Tile("Gusts", text, Icons.Filled.Air, DetailNotes.gusts(gusts, now.windSpeed))
    }
    val trend = forecast.pressureTrend()
    WeatherFormat.pressure(now.pressure ?: hour?.pressure)?.let {
        tiles += Tile("Pressure", it, Icons.Filled.Speed, trend?.note ?: "", trend?.direction)
    }
    (now.humidity ?: hour?.humidity)?.let {
        tiles += Tile("Humidity", WeatherFormat.percent(it), Icons.Filled.WaterDrop, DetailNotes.humidity(hour?.dewPoint))
    }
    hour?.visibility?.let { m ->
        val km = m / 1000
        WeatherFormat.distance(km)?.let { tiles += Tile("Visibility", it, Icons.Filled.Visibility, DetailNotes.visibility(km)) }
    }
    val rise = day?.sunrise
    val set = day?.sunset
    if (rise != null && set != null) {
        val mins = ((set - rise) / 60).toInt()
        tiles += Tile("Daylight", "${mins / 60} hr ${mins % 60} min", Icons.Filled.WbTwilight, "Sunset ${TimeText.time(set, zone)}.")
    }
    if (day != null && (day.rainSum != null || day.snowfallSum != null)) {
        val t = WeatherFormat.precipitationTotals(day.rainSum, day.snowfallSum) ?: "None"
        val weekTotals = forecast.precipitationTotals(7)
        val week = weekTotals?.let { WeatherFormat.precipitationTotals(it.first, it.second) ?: "none" }
        val r = day.rainSum ?: 0.0
        val s = day.snowfallSum ?: 0.0
        val icon = when {
            r > 0 && s > 0 -> Icons.Filled.Grain
            s > 0 -> Icons.Filled.AcUnit
            r > 0 -> Icons.Filled.WaterDrop
            weekTotals != null && weekTotals.first > 0 && weekTotals.second > 0 -> Icons.Filled.Grain
            weekTotals != null && weekTotals.second > 0 -> Icons.Filled.AcUnit
            weekTotals != null && weekTotals.first > 0 -> Icons.Filled.WaterDrop
            else -> Icons.Filled.Grain
        }
        tiles += Tile("Rain and snow today", t, icon, week?.let { "Next 7 days: $it." } ?: "")
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (rise != null && set != null) SunArc(rise, set, zone)
        MoonRow(zone)
        tiles.chunked(2).forEach { row ->
            Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (t in row) {
                    Column(Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f)).padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(t.icon, null, tint = White82, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(t.title, style = style(13.sp, FontWeight.Medium, White82))
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(t.value, style = style(17.sp, FontWeight.SemiBold))
                            if (t.trend != null) {
                                Spacer(Modifier.width(4.dp))
                                Icon(when { t.trend > 0 -> Icons.Filled.ArrowUpward; t.trend < 0 -> Icons.Filled.ArrowDownward; else -> Icons.AutoMirrored.Filled.ArrowForward },
                                    null, tint = Gold, modifier = Modifier.size(14.dp))
                            }
                        }
                        if (t.note.isNotEmpty()) Text(t.note, style = style(12.sp, color = Color.White.copy(alpha = 0.8f)))
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** The sun's path from sunrise to sunset, with the sun where it is now. */
@Composable
fun SunArc(sunrise: Epoch, sunset: Epoch, zone: String) {
    val now = nowEpoch()
    val span = sunset - sunrise
    val t = if (span > 0) min(max((now - sunrise) / span, 0.0), 1.0) else 0.0
    val up = now >= sunrise && now < sunset
    fun duration(s: Double): String {
        val m = max((s / 60).toInt(), 1)
        return if (m < 60) "$m min" else if (m % 60 == 0) "${m / 60} hr" else "${m / 60} hr ${m % 60} min"
    }
    val caption = when {
        now < sunrise -> "Sunrise in ${duration(sunrise - now)}"
        now < sunset -> "Sunset in ${duration(sunset - now)}"
        else -> "The sun has set"
    }
    Column(Modifier.clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f)).padding(10.dp)) {
        Canvas(Modifier.fillMaxWidth().height(86.dp)) {
            val base = size.height - 8.dp.toPx()
            val w = size.width - 24.dp.toPx()
            val h = base - 14.dp.toPx()
            fun point(p: Double) = Offset((12.dp.toPx() + p * w).toFloat(), (base - sin(p * PI) * h).toFloat())
            val arc = androidx.compose.ui.graphics.Path().apply {
                val p0 = point(0.0); moveTo(p0.x, p0.y)
                for (i in 1..60) { val p = point(i / 60.0); lineTo(p.x, p.y) }
            }
            drawPath(arc, Color.White.copy(alpha = 0.45f), style = Stroke(2.dp.toPx(), cap = StrokeCap.Round,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 5.dp.toPx()))))
            if (t > 0) {
                val done = androidx.compose.ui.graphics.Path().apply {
                    val p0 = point(0.0); moveTo(p0.x, p0.y)
                    val steps = max((t * 60).toInt(), 1)
                    for (i in 1..steps) { val p = point(t * i / steps); lineTo(p.x, p.y) }
                }
                drawPath(done, Gold, style = Stroke(3.dp.toPx(), cap = StrokeCap.Round))
            }
            drawLine(Color.White.copy(alpha = 0.5f), Offset(0f, base), Offset(size.width, base), 1.dp.toPx())
            val sun = point(t)
            val r = 9.dp.toPx()
            if (up) {
                drawCircle(Gold.copy(alpha = 0.25f), 2 * r, sun)
                drawCircle(Gold, r, sun)
            } else drawCircle(Color.White.copy(alpha = 0.35f), r, sun)
        }
        Spacer(Modifier.height(6.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Column {
                Text("Sunrise", style = style(13.sp, FontWeight.Medium, White82))
                Text(TimeText.time(sunrise, zone), style = style(17.sp, FontWeight.SemiBold))
            }
            Text(caption, style = style(13.sp, FontWeight.SemiBold, Gold), modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Column(horizontalAlignment = Alignment.End) {
                Text("Sunset", style = style(13.sp, FontWeight.Medium, White82))
                Text(TimeText.time(sunset, zone), style = style(17.sp, FontWeight.SemiBold))
            }
        }
    }
}

/** Tonight's moon: phase, name, how much is lit and the next full moon. */
@Composable
fun MoonRow(zone: String) {
    val moon = MoonPhase(nowEpoch())
    val full = moon.nextFullMoon(nowEpoch())
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f)).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        MoonGlyph(moon.illumination, moon.age < MoonPhase.synodicMonth / 2)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(moon.name, style = style(17.sp, FontWeight.SemiBold))
            Text("${(moon.illumination * 100).rndInt()}% lit", style = style(13.sp, color = White82))
        }
        Column(horizontalAlignment = Alignment.End) {
            Text("Full moon", style = style(13.sp, FontWeight.Medium, White82))
            Text(TimeText.format(full, zone, "EEE, MMM d"), style = style(17.sp, FontWeight.SemiBold))
        }
    }
}

/** The lit part of the moon: waxing lights the right side, waning the left. */
@Composable
fun MoonGlyph(illumination: Double, waxing: Boolean) {
    Canvas(Modifier.size(28.dp)) {
        val r = size.minDimension / 2
        val c = center
        drawCircle(Color.White.copy(alpha = 0.2f), r, c)
        val path = androidx.compose.ui.graphics.Path()
        val k = (1 - 2 * illumination).toFloat() // terminator ellipse x-radius factor
        val steps = 40
        val side = if (waxing) 1f else -1f
        for (i in 0..steps) {
            val a = -PI / 2 + PI * i / steps
            val x = c.x + side * r * kotlin.math.cos(a).toFloat()
            val y = c.y + r * kotlin.math.sin(a).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        for (i in steps downTo 0) {
            val a = -PI / 2 + PI * i / steps
            val x = c.x + side * k * r * kotlin.math.cos(a).toFloat()
            val y = c.y + r * kotlin.math.sin(a).toFloat()
            path.lineTo(x, y)
        }
        path.close()
        drawPath(path, Color.White)
    }
}
