package com.khanweather.app

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Public
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material3.CircularProgressIndicator
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

private object ModelCache {
    var key: String? = null
    var days: List<ModelDay> = emptyList()
    var at = 0.0
}

private suspend fun loadModels(location: Coordinate): List<ModelDay>? {
    val key = ObservationMemory.key(location)
    if (ModelCache.key == key && nowEpoch() - ModelCache.at < 30 * 60 && ModelCache.days.isNotEmpty()) return ModelCache.days
    val d = runCatching { ModelComparisonProvider().days(location) }.getOrNull() ?: return null
    ModelCache.key = key; ModelCache.days = d; ModelCache.at = nowEpoch()
    return d
}

@Composable
private fun Loading(text: String) {
    Column(Modifier.fillMaxWidth().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator(color = Color.White)
        Spacer(Modifier.height(10.dp))
        Text(text, style = style(16.sp))
    }
}

/** One day as several weather models see it. */
@Composable
fun ModelComparisonScreen(day: DailyForecast, forecast: Forecast, nav: (Screen) -> Unit) {
    val location = forecast.location
    val zone = forecast.timeZoneIdentifier
    val used = WeatherModel.usedForTemperatures(location)
    var rows by remember { mutableStateOf<List<ModelDay>?>(null) }
    var extSources by remember { mutableStateOf<List<WeatherLoader.RelayConsensus.Source>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(day.date) {
        coroutineScope {
            val extTask = async { WeatherLoader.relayConsensus(location) }
            val all = loadModels(location)
            if (all != null) {
                val same = all.filter { forecast.cal.isSameDay(it.date, day.date) }
                val ordered = same.filter { it.model == used } + same.filter { it.model != used }
                rows = ModelComparisonProvider.showingApp(ordered, forecast.daily, used, zone)
            }
            extSources = extTask.await()?.sources.orEmpty()
        }
        loading = false
    }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        val r = rows
        if (loading) Loading("Asking each model…")
        else if (r.isNullOrEmpty()) Section(null, null) { Text("Couldn't load the models. Check your connection and try again.", style = style(16.sp)) }
        else {
            if (extSources.isNotEmpty()) {
                Section("Other weather services", Icons.Filled.Public, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
                    extSources.forEachIndexed { i, src ->
                        Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(src.provider, style = style(15.sp, FontWeight.SemiBold))
                                src.condition?.let {
                                    Text(it, style = style(12.sp, color = Color.White.copy(alpha = 0.72f)))
                                }
                            }
                            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("Now ${WeatherFormat.temperature(src.temperature)}", style = style(15.sp, FontWeight.Bold))
                                if (src.high != null && src.low != null) {
                                    Text("${WeatherFormat.temperature(src.high)} / ${WeatherFormat.temperature(src.low)}",
                                        style = style(12.sp, color = Color.White.copy(alpha = 0.7f)))
                                }
                            }
                        }
                        if (i < extSources.size - 1) RowDivider()
                    }
                }
            }
            val highs = r.mapNotNull { it.high }
            if (highs.size >= 2) {
                val unit = UnitSettings.current.temperature
                val spread = (unit.convert(highs.max()) - unit.convert(highs.min())).rndInt()
                val text = if (spread <= 2) "The models agree on the high within $spread°. This forecast is fairly sure."
                else "The models differ on the high, from ${WeatherFormat.temperature(highs.min())} to ${WeatherFormat.temperature(highs.max())}. Treat this day as less certain."
                Section(null, null) { LabelLine(Icons.Filled.BarChart, text) }
            }
            Section("High and low by model", Icons.Filled.BarChart, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
                r.forEachIndexed { i, row ->
                    Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconBadge(row.condition, true, 36.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(row.model.displayName, style = style(15.sp, if (row.model == used) FontWeight.Bold else FontWeight.SemiBold))
                            if (row.model == used) GoldPill("Used by Khan Weather", 10.sp)
                            WeatherFormat.precipitationTotals(row.rainMm, row.snowCm)?.let { Text(it, style = style(12.sp, FontWeight.Medium, Color.White.copy(alpha = 0.75f))) }
                        }
                        Text(WeatherFormat.temperature(row.high), style = style(17.sp, FontWeight.Bold), modifier = Modifier.width(40.dp))
                        Text(WeatherFormat.temperature(row.low), style = style(17.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.7f)), modifier = Modifier.width(40.dp))
                    }
                    if (i < r.size - 1) RowDivider()
                }
            }
            val source = if (used == WeatherModel.blend) BlendRegion.summary(location)
            else "Khan Weather's temperatures here come from ${used.displayName}."
            Text(source + " The highlighted row's high and low come from the app's midnight-to-midnight hourly forecast, on the same 24-hour window as the other models. High-res models only reach a day or two ahead. Models via Open-Meteo.com (CC BY 4.0).",
                style = style(12.sp, color = Color.White.copy(alpha = 0.8f)), modifier = Modifier.padding(horizontal = 32.dp).padding(bottom = 14.dp))
        }
        Section(null, null, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
            LinkRow({ nav(Screen.ModelGrid) }) {
                Icon(Icons.Filled.GridView, null, tint = Gold, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text("All models, all 10 days", style = style(15.sp, FontWeight.SemiBold))
            }
            RowDivider()
            LinkRow({ nav(Screen.Accuracy) }) {
                Icon(Icons.Filled.TrackChanges, null, tint = Gold, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text("Which model has been most accurate?", style = style(15.sp, FontWeight.SemiBold))
            }
        }
    }
}

/** Every model's high and low for every day, side by side. */
@Composable
fun ModelGridScreen(forecast: Forecast) {
    val location = forecast.location
    val zone = forecast.timeZoneIdentifier
    var days by remember { mutableStateOf<List<ModelDay>?>(null) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(location) {
        val all = loadModels(location)
        days = all?.let { ModelComparisonProvider.showingApp(it, forecast.daily, WeatherModel.usedForTemperatures(location), zone) }
        loading = false
    }
    val d = days
    if (loading) { Loading("Asking each model…"); return }
    if (d.isNullOrEmpty()) { Section(null, null) { Text("Couldn't load the models. Check your connection and try again.", style = style(16.sp)) }; return }
    val used = WeatherModel.usedForTemperatures(location)
    val present = d.map { it.model }.toSet()
    val models = listOf(used) + WeatherModel.entries.filter { it != used && it in present }
    val dates = d.map { it.date }.distinct().sorted()
    fun confidence(date: Epoch): ForecastConfidence? {
        val same = d.filter { it.date == date && it.model != WeatherModel.blend && it.model != WeatherModel.bestMatch }
        val highs = same.mapNotNull { it.high }; val lows = same.mapNotNull { it.low }
        if (highs.size < 3 || lows.isEmpty()) return null
        val spread = ((highs.max() - highs.min()) + (lows.max() - lows.min())) / 2
        return if (spread <= 2.5) ForecastConfidence.sure else if (spread <= 4.5) ForecastConfidence.fair else ForecastConfidence.unsure
    }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.clip(RoundedCornerShape(18.dp)).background(Color.Black.copy(alpha = 0.22f)).padding(vertical = 8.dp)) {
            Column {
                Spacer(Modifier.height(44.dp))
                for (m in models) Box(Modifier.width(112.dp).height(54.dp).padding(start = 10.dp), contentAlignment = Alignment.CenterStart) {
                    Text(m.displayName, style = style(12.sp, if (m == used) FontWeight.ExtraBold else FontWeight.SemiBold, if (m == used) Gold else Color.White), maxLines = 2)
                }
            }
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                dates.forEachIndexed { i, date ->
                    Column {
                        Column(Modifier.width(58.dp).height(44.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                            Text(if (i == 0) "Today" else TimeText.weekdayShort(date, zone), style = style(12.sp, FontWeight.ExtraBold, if (i == 0) Gold else Color.White))
                            confidence(date)?.let { Spacer(Modifier.height(3.dp)); ConfidenceMark(it) }
                        }
                        for (m in models) {
                            val cell = d.firstOrNull { it.model == m && it.date == date }
                            Column(Modifier.width(58.dp).height(54.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                                if (cell != null) {
                                    ConditionIcon(cell.condition, true, 16.dp)
                                    Text(WeatherFormat.temperature(cell.high), style = style(15.sp, FontWeight.Bold))
                                    Text(WeatherFormat.temperature(cell.low), style = style(12.sp, FontWeight.Medium, Color.White.copy(alpha = 0.7f)))
                                } else Text("–", style = style(15.sp, color = Color.White.copy(alpha = 0.4f)))
                            }
                        }
                    }
                }
            }
        }
        Text("High over low for each day. The bars under a day show how well the models agree. Models via Open-Meteo.com (CC BY 4.0).",
            style = style(12.sp, color = Color.White.copy(alpha = 0.8f)))
    }
}
