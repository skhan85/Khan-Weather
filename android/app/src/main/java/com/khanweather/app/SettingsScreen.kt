package com.khanweather.app

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.app.widget.Widgets
import com.khanweather.core.*

@Composable
fun SettingsScreen(onChanged: () -> Unit) {
    val context = LocalContext.current
    var version by remember { mutableIntStateOf(0) }
    fun changed() { version++; onChanged(); Widgets.updateAllAsync(context) }
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        Notifier.schedule(context)
    }
    key(version) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
            Section("Units", Icons.Filled.Straighten, PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
                Choice("Units", UnitPreset.entries, Prefs.units.preset, { it?.label ?: "Custom" }) { p -> p?.let { Prefs.saveUnits(it.settings) }; changed() }
                RowDivider()
                Choice("Temperature", TemperatureUnit.entries, Prefs.temperatureUnit, { it.label }) { Prefs.temperatureUnit = it; changed() }
                RowDivider()
                Choice("Wind", WindUnit.entries, Prefs.windUnit, { it.label }) { Prefs.windUnit = it; changed() }
                RowDivider()
                Choice("Rain and snow", PrecipitationUnit.entries, Prefs.precipitationUnit, { it.label }) { Prefs.precipitationUnit = it; changed() }
                RowDivider()
                Choice("Pressure", PressureUnit.entries, Prefs.pressureUnit, { it.label }) { Prefs.pressureUnit = it; changed() }
                RowDivider()
                Choice("Distance and visibility", DistanceUnit.entries, Prefs.distanceUnit, { it.label }) { Prefs.distanceUnit = it; changed() }
            }
            Section("Notifications", Icons.Filled.Notifications, PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
                SettingSwitch("Severe weather alerts", Prefs.alertNotifications) { Prefs.alertNotifications = it; if (it) ensureNotificationPermission(); changed() }
                if (Prefs.alertNotifications) {
                    RowDivider()
                    SettingSwitch("Include advisories and statements", Prefs.advisoryNotifications) { Prefs.advisoryNotifications = it; changed() }
                }
                RowDivider()
                SettingSwitch("Rain or snow starting soon", Prefs.rainNotifications) { Prefs.rainNotifications = it; if (it) ensureNotificationPermission(); changed() }
                RowDivider()
                SettingSwitch("Frost tonight", Prefs.frostNotifications) { Prefs.frostNotifications = it; if (it) ensureNotificationPermission(); changed() }
                RowDivider()
                Text("Send a test notification", style = style(16.sp, FontWeight.SemiBold, ChanceBlue),
                    modifier = Modifier.fillMaxWidth().clickable { ensureNotificationPermission(); Notifier.sendTest(context) }.padding(vertical = 12.dp))
            }
            Note("Warnings and watches from Environment Canada, the US National Weather Service and Germany's DWD, for your location and saved places. Rain and frost heads-ups are for your current location. Khan Weather checks about every 30 minutes in the background.")
            Section("Main screen", Icons.Filled.Home, PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
                Choice("Big number shows", listOf(false, true), Prefs.feelsLikeFirst, { if (it) "Feels like" else "Actual" }) { Prefs.feelsLikeFirst = it; changed() }
                RowDivider()
                Choice("Hourly forecast", listOf(24, 48), Prefs.hourlyCount, { "$it hours" }) { Prefs.hourlyCount = it; changed() }
                RowDivider()
                SettingSwitch("Today's details", Prefs.showDetails) { Prefs.showDetails = it; changed() }
                RowDivider()
                SettingSwitch("Air quality", Prefs.showAirQuality) { Prefs.showAirQuality = it; changed() }
            }
            Section("Observations", Icons.Filled.Sensors, PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
                SettingSwitch("Home weather stations", Prefs.hyperlocal) { Prefs.hyperlocal = it; changed() }
            }
            Note("Uses nearby personal weather stations when available, falling back to official stations. On by default.")
            Section("Display", Icons.Filled.Palette, PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
                Choice("Time format", listOf("automatic", "twelveHour", "twentyFourHour"), Prefs.clock,
                    { when (it) { "twelveHour" -> "12-hour"; "twentyFourHour" -> "24-hour"; else -> "Automatic" } }) { Prefs.clock = it; changed() }
            }
            Section("About", Icons.Filled.Info, PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
                val v = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull()
                Labeled("Version", v ?: "")
                Text("Khan Weather for Android. Same forecast, blend and sources as the iPhone app.", style = style(13.sp, color = White82))
            }
        }
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = style(12.sp, color = Color.White.copy(alpha = 0.8f)), modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 0.dp, bottom = 14.dp).offset(y = (-8).dp))
}

@Composable
private fun SettingSwitch(title: String, on: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { set(!on) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = style(16.sp), modifier = Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = set, colors = SwitchDefaults.colors(checkedTrackColor = Gold, checkedThumbColor = Color.White))
    }
}

@Composable
private fun <T> Choice(title: String, options: List<T>, selected: T, label: (T) -> String, set: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = style(16.sp), modifier = Modifier.weight(1f))
            Text(label(selected), style = style(16.sp, color = White82))
            Icon(Icons.Filled.UnfoldMore, null, tint = White82, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(open, { open = false }) {
            for (o in options) DropdownMenuItem(text = { Text(label(o)) }, onClick = { open = false; set(o) })
        }
    }
}
