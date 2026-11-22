package com.khanweather.app

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.*
import java.util.Locale

/** The big card at the top of the hour and day screens, in the same style as the Now card. */
@Composable
fun DetailHero(tag: String, condition: WeatherCondition, isDay: Boolean, temperature: String, headline: String, detail: String?) {
    Column(Modifier.heroCard(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        GoldPill(tag.uppercase(), 12.sp)
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconBadge(condition, isDay, 88.dp)
            Spacer(Modifier.width(16.dp))
            Column {
                Text(temperature, style = style(56.sp, FontWeight.Bold, shadow = true), maxLines = 1)
                Text(headline, style = style(20.sp, FontWeight.SemiBold, shadow = true))
                detail?.let { Text(it, style = style(17.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.9f), shadow = true)) }
            }
        }
    }
}

@Composable
fun DetailRow(title: String, value: String?, icon: ImageVector) {
    if (value == null) return
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Gold, modifier = Modifier.width(28.dp).size(20.dp))
        Spacer(Modifier.width(12.dp))
        Text(title, style = style(17.sp, FontWeight.Medium, Color.White.copy(alpha = 0.85f)), modifier = Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Text(value, style = style(17.sp, FontWeight.Bold), textAlign = TextAlign.End)
    }
}

private fun chanceText(p: Double?, kind: PrecipitationKind) = p?.let { "${WeatherFormat.percent(it)} chance of ${kind.noun}" }

private fun windText(speed: Double?, gusts: Double?, direction: Double?): String? {
    speed ?: return null
    var text = WeatherFormat.wind(speed)
    WeatherFormat.compass(direction)?.let { text = "$it $text" }
    if (gusts != null && gusts >= speed + 10) text += ", gusts ${WeatherFormat.wind(gusts)}"
    return text
}

private fun precipIcon(kind: PrecipitationKind) = if (kind == PrecipitationKind.snow) Icons.Filled.AcUnit else Icons.Filled.WaterDrop

@Composable
fun HourScreen(hour: HourlyForecast, zone: String) {
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        DetailHero(TimeText.weekdayHour(hour.time, zone), hour.condition, hour.isDay, WeatherFormat.temperature(hour.temperature),
            hour.condition.description, hour.feelsLike?.let { "Feels like ${WeatherFormat.temperature(it)}" })
        Spacer(Modifier.height(14.dp))
        Section("Details", Icons.AutoMirrored.Filled.List, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
            DetailRow("Precipitation", chanceText(hour.precipitationProbability, hour.precipitationKind), precipIcon(hour.precipitationKind))
            DetailRow("Amount", WeatherFormat.precipitationTotals(hour.rain, hour.snowfall), Icons.Filled.Opacity)
            DetailRow("Wind", windText(hour.windSpeed, hour.windGusts, hour.windDirection), Icons.Filled.Air)
            DetailRow("Humidity", hour.humidity?.let { WeatherFormat.percent(it) }, Icons.Filled.WaterDrop)
            DetailRow("Dew point", hour.dewPoint?.let { WeatherFormat.temperature(it) }, Icons.Filled.Thermostat)
            DetailRow("UV index", WeatherFormat.uvLevel(hour.uvIndex), Icons.Filled.WbSunny)
            DetailRow("Visibility", hour.visibility?.let { WeatherFormat.distance(it / 1000) }, Icons.Filled.Visibility)
        }
    }
}

@Composable
fun DayScreen(day: DailyForecast, forecast: Forecast, normals: ClimateNormals?, nav: (Screen) -> Unit) {
    val zone = forecast.timeZoneIdentifier
    val hours = forecast.hoursOn(day)
    val normal = normals?.takeIf { it.covers(forecast.location) }?.normal(day.date, zone)
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        val feels = if (day.feelsLikeHigh != null && day.feelsLikeLow != null)
            "Feels like ${WeatherFormat.temperature(day.feelsLikeHigh)} / ${WeatherFormat.temperature(day.feelsLikeLow)}" else null
        DetailHero(TimeText.weekday(day.date, zone), day.condition, true,
            "${WeatherFormat.temperature(day.high)} / ${WeatherFormat.temperature(day.low)}", day.summary ?: day.condition.description, feels)
        Spacer(Modifier.height(14.dp))
        if (hours.isNotEmpty()) Section("Hour by hour", Icons.Filled.Schedule, PaddingValues(vertical = 8.dp)) {
            HourlyCurve(hours, zone, firstIsNow = false) { nav(Screen.Hour(it, zone)) }
        }
        Section("Details", Icons.AutoMirrored.Filled.List, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
            DetailRow("Precipitation", chanceText(day.precipitationProbability, day.precipitationKind), precipIcon(day.precipitationKind))
            DetailRow("Total", WeatherFormat.precipitationTotals(day.rainSum, day.snowfallSum), Icons.Filled.Opacity)
            DetailRow("Hours of precipitation", day.precipitationHours?.takeIf { it > 0 }?.let { "${it.rndInt()} h" }, Icons.Filled.Schedule)
            DetailRow("Wind", windText(day.windSpeedMax, day.windGustsMax, day.windDirectionDominant), Icons.Filled.Air)
            DetailRow("UV index", WeatherFormat.uvLevel(day.uvIndexMax), Icons.Filled.WbSunny)
            DetailRow("Forecast confidence", day.confidence?.let {
                val half = (day.modelSpread ?: 0.0) / 2 * (if (UnitSettings.current.temperature == TemperatureUnit.fahrenheit) 1.8 else 1.0)
                "${it.label} (±${String.format(Locale.US, "%.0f", half)}°)"
            }, Icons.Filled.Verified)
            DetailRow("Normal for the date", normal?.let { "${WeatherFormat.temperature(it.first)} / ${WeatherFormat.temperature(it.second)}" }, Icons.Filled.Event)
            DetailRow("Sunrise", day.sunrise?.let { TimeText.time(it, zone) }, Icons.Filled.WbTwilight)
            DetailRow("Sunset", day.sunset?.let { TimeText.time(it, zone) }, Icons.Filled.WbTwilight)
        }
        Section(null, null, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
            LinkRow({ nav(Screen.Models(day)) }) {
                Icon(Icons.Filled.BarChart, null, tint = Gold, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text("Compare forecast models", style = style(17.sp, FontWeight.SemiBold))
            }
        }
    }
}

@Composable
fun SourcesScreen(forecast: Forecast, alerts: List<WeatherAlert>, isSavedPlace: Boolean) {
    val context = LocalContext.current
    val zone = forecast.timeZoneIdentifier
    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        Section("Sources", Icons.Filled.Info, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
            SourceLink("Forecast: Open-Meteo.com (CC BY 4.0)") { open("https://open-meteo.com/") }
            for (c in Credits.full(forecast, alerts)) SourceLink(c.first) { open(c.second) }
            val o = forecast.observation
            if (o?.dataProvider == "ON-MTO" || o?.skyDataProvider == "ON-MTO") {
                Text("Road weather station: Ontario Ministry of Transportation", style = style(16.sp), modifier = Modifier.padding(vertical = 8.dp))
            }
            if (isSavedPlace) SourceLink("Place search: Open-Meteo and GeoNames (CC BY 4.0)") { open("https://www.geonames.org/") }
            Text("Updated ${TimeText.time(forecast.fetchedAt, java.time.ZoneId.systemDefault().id)}",
                style = style(13.sp, color = White82), modifier = Modifier.padding(vertical = 6.dp))
        }
        forecast.observation?.let { o ->
            Section("Right now", Icons.Filled.NearMe, PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
                Labeled("Station", o.stationName)
                WeatherFormat.distance(o.distanceKm)?.let { Labeled("Distance", it) }
                Labeled("Observed", TimeText.time(o.observedAt, zone))
                o.stationTemperatures?.size?.takeIf { it > 1 }?.let { Labeled("PWS sensors", "$it nearby") }
                o.rainGauges?.takeIf { it > 0 }?.let { g ->
                    val s = if (g == 1) "" else "s"
                    Labeled("Rain gauges", if ((o.rainLastHourMm ?: 0.0) > 0)
                        "${WeatherFormat.rainAmount(o.rainLastHourMm ?: 0.0)} in last hr ($g gauge$s)" else "Dry ($g gauge$s)")
                }
                o.skyStationName?.let { Labeled("Sky from", it) }
                forecast.radar?.let { Labeled("Radar scan", TimeText.time(it.time, zone)) }
            }
        }
    }
}

@Composable
private fun SourceLink(text: String, onClick: () -> Unit) {
    Text(text, style = style(16.sp, FontWeight.Medium, ChanceBlue), modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp))
}

@Composable
fun Labeled(title: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 7.dp)) {
        Text(title, style = style(16.sp), modifier = Modifier.weight(1f))
        Text(value, style = style(16.sp, color = White82), textAlign = TextAlign.End)
    }
}

/** Who supplied what, for the one-line credit and the full Sources page. */
object Credits {
    private fun observation(provider: String?): Pair<String, Pair<String, String>> = when (provider) {
        "NWS" -> "US National Weather Service" to ("Observations: US National Weather Service" to "https://www.weather.gov/")
        "DWD" -> "Deutscher Wetterdienst" to ("Observations: Deutscher Wetterdienst via Bright Sky" to "https://brightsky.dev/")
        "NETATMO" -> "Netatmo" to ("Temperature: nearby Netatmo personal weather stations" to "https://weathermap.netatmo.com/")
        "METAR" -> "NOAA Aviation Weather" to ("Airport observations: NOAA Aviation Weather Center" to "https://aviationweather.gov/")
        else -> "Environment Canada" to ("Observations: Environment and Climate Change Canada" to "https://weather.gc.ca/")
    }

    private fun alertCredit(source: String): Pair<String, Pair<String, String>> = when (source) {
        "US National Weather Service" -> source to ("Alerts: US National Weather Service" to "https://alerts.weather.gov/")
        "Deutscher Wetterdienst" -> source to ("Alerts: Deutscher Wetterdienst via Bright Sky" to "https://www.dwd.de/")
        else -> "Environment Canada" to ("Alerts: Environment and Climate Change Canada" to "https://weather.gc.ca/")
    }

    private fun all(forecast: Forecast, alerts: List<WeatherAlert>): List<Pair<String, Pair<String, String>>> {
        val list = mutableListOf<Pair<String, Pair<String, String>>>()
        forecast.observation?.let { o ->
            list += observation(o.dataProvider)
            if (o.dataProvider == "NETATMO" && o.skyStationName != null) {
                val (name, credit) = observation(o.skyDataProvider)
                list += name to (credit.first.replace("Airport observations", "Sky").replace("Observations", "Sky") to credit.second)
            }
        }
        if (forecast.radar != null) list += "Environment Canada" to ("Radar: Environment and Climate Change Canada" to "https://weather.gc.ca/")
        for (s in alerts.map { it.source }.toSortedSet()) list += alertCredit(s)
        return list
    }

    fun shortNames(forecast: Forecast, alerts: List<WeatherAlert>): List<String> {
        val names = mutableListOf("Open-Meteo")
        for ((name, _) in all(forecast, alerts)) if (name !in names) names += name
        val o = forecast.observation
        if (o?.dataProvider == "ON-MTO" || o?.skyDataProvider == "ON-MTO") names += "Ontario MTO"
        return names
    }

    fun full(forecast: Forecast, alerts: List<WeatherAlert>): List<Pair<String, String>> = all(forecast, alerts).map { it.second }
}
