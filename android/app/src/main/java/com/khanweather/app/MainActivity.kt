package com.khanweather.app

import android.Manifest
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.khanweather.core.*

/** Screens reached from the main list. */
sealed class Screen {
    data object Main : Screen()
    data class Hour(val hour: HourlyForecast, val zone: String) : Screen()
    data class Day(val day: DailyForecast, val index: Int) : Screen()
    data class Models(val day: DailyForecast) : Screen()
    data object ModelGrid : Screen()
    data object Accuracy : Screen()
    data object Radar : Screen()
    data object Sources : Screen()
    data object Settings : Screen()
    data object Places : Screen()
}

class MainActivity : ComponentActivity() {
    private val model: WeatherViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Prefs.init(this)
        TimeText.is24hSystem = android.text.format.DateFormat.is24HourFormat(this)
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        val widgetPreview = intent?.getBooleanExtra("widgetPreview", false) == true
        // CI screenshots: `--es units us` answers the first-launch question.
        intent?.getStringExtra("units")?.let { name ->
            UnitPreset.entries.firstOrNull { it.name == name }?.let { Prefs.saveUnits(it.settings); Prefs.unitsChosen = true }
        }
        setContent {
            if (widgetPreview) Box(Modifier.fillMaxSize()) {
                SkyBackground(WeatherCondition.overcast, true)
                Box(Modifier.systemBarsPadding()) { com.khanweather.app.widget.WidgetPreviewScreen() }
            } else App(model)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun App(model: WeatherViewModel) {
    var stack by remember { mutableStateOf(listOf<Screen>(Screen.Main)) }
    var selectedId by remember { mutableStateOf(Prefs.selectedPlaceId?.takeIf { id -> Prefs.places.any { it.id == id } }) }
    var settingsVersion by remember { mutableIntStateOf(0) }
    var unitsChosen by remember { mutableStateOf(Prefs.unitsChosen) }
    val screen = stack.last()
    fun nav(s: Screen) { stack = stack + s }
    fun back() { if (stack.size > 1) stack = stack.dropLast(1) }
    fun selectedPlace() = Prefs.places.firstOrNull { it.id == selectedId }
    fun reload() = model.reload(selectedPlace())
    BackHandler(enabled = stack.size > 1) { back() }

    val askLocation = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { reload() }
    val context = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(Unit) {
        if (!LocationHelper.hasPermission(context)) {
            askLocation.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
        } else reload()
        Notifier.schedule(context)
    }
    // Coming back after two minutes refreshes (Open-Meteo answers HTTP 429 when hit too often).
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_RESUME && model.lastReload > 0 && nowEpoch() - model.lastReload > 120) reload()
        }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    val state = model.state
    val forecast = (state as? LoadState.Loaded)?.forecast
    val sky = when (screen) {
        is Screen.Hour -> screen.hour.condition to screen.hour.isDay
        is Screen.Day -> screen.day.condition to true
        is Screen.Models -> screen.day.condition to true
        else -> (forecast?.current?.condition ?: WeatherCondition.partlyCloudy) to (forecast?.current?.isDay ?: true)
    }

    Box(Modifier.fillMaxSize()) {
        SkyBackground(sky.first, sky.second)
        if (!unitsChosen) {
            Box(Modifier.fillMaxSize().systemBarsPadding()) {
                UnitsWelcomeScreen { unitsChosen = true; settingsVersion++; com.khanweather.app.widget.Widgets.updateAllAsync(context) }
            }
            return@Box
        }
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            TopBar(screen, forecast, onBack = ::back, onSettings = { nav(Screen.Settings) }, onPlaces = { nav(Screen.Places) },
                isSavedPlace = selectedId != null)
            Box(Modifier.weight(1f)) {
                key(settingsVersion) {
                    when (screen) {
                        Screen.Main -> PullToRefreshBox(isRefreshing = model.refreshing && forecast != null, onRefresh = { reload() }) {
                            run {
                                when (state) {
                                    LoadState.Loading -> Centered {
                                        CircularProgressIndicator(color = Color.White)
                                        Spacer(Modifier.height(12.dp))
                                        Text("Getting your weather…", style = style(16.sp))
                                    }
                                    is LoadState.Failed -> Centered {
                                        Icon(Icons.Filled.Warning, null, tint = Color.White, modifier = Modifier.size(40.dp))
                                        Text("Couldn't load weather", style = style(20.sp, FontWeight.Bold))
                                        Text(state.message, style = style(15.sp, color = White82))
                                        Spacer(Modifier.height(10.dp))
                                        OutlinedButton(onClick = { reload() }) { Text("Try again", color = Color.White) }
                                    }
                                    is LoadState.Loaded -> ForecastList(state.forecast, model.alerts, model.airQuality, model.normals,
                                        model.placeName, selectedId != null, model.usingFallbackLocation, ::nav)
                                }
                            }
                        }
                        is Screen.Hour -> HourScreen(screen.hour, screen.zone)
                        is Screen.Day -> forecast?.let { DayScreen(screen.day, it, model.normals, ::nav) }
                        is Screen.Models -> forecast?.let { ModelComparisonScreen(screen.day, it, ::nav) }
                        Screen.ModelGrid -> forecast?.let { ModelGridScreen(it) }
                        Screen.Accuracy -> AccuracyScreen()
                        Screen.Radar -> RadarScreen(forecast?.location ?: Coordinate.fallback)
                        Screen.Sources -> forecast?.let { SourcesScreen(it, model.alerts, selectedId != null) }
                        Screen.Settings -> SettingsScreen { settingsVersion++; Prefs.applyUnits() }
                        Screen.Places -> PlacesScreen(selectedId) { id ->
                            selectedId = id
                            Prefs.selectedPlaceId = id
                            back()
                            reload()
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Centered(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center, content = content)
}

@Composable
private fun TopBar(screen: Screen, forecast: Forecast?, onBack: () -> Unit, onSettings: () -> Unit, onPlaces: () -> Unit, isSavedPlace: Boolean) {
    val zone = forecast?.timeZoneIdentifier ?: java.time.ZoneId.systemDefault().id
    val title = when (screen) {
        is Screen.Hour -> TimeText.weekdayHour(screen.hour.time, screen.zone)
        is Screen.Day -> TimeText.weekdayMonthDay(screen.day.date, zone)
        is Screen.Models -> "Compare models"
        Screen.ModelGrid -> "10-day models"
        Screen.Accuracy -> "Forecast accuracy"
        Screen.Radar -> "Radar"
        Screen.Sources -> "Sources"
        Screen.Settings -> "Settings"
        Screen.Places -> "Places"
        Screen.Main -> null
    }
    Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        if (screen == Screen.Main) {
            IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, "Settings", tint = Color.White) }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                Image(painterResource(R.drawable.logo), "Khan Weather",
                    Modifier.size(30.dp).clip(RoundedCornerShape(7.dp)).border(0.5.dp, Color.White.copy(alpha = 0.35f), RoundedCornerShape(7.dp)))
            }
            IconButton(onClick = onPlaces) {
                Icon(if (isSavedPlace) Icons.Filled.PinDrop else Icons.Filled.MyLocation, "Places", tint = Color.White)
            }
        } else {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White) }
            Text(title ?: "", style = style(17.sp, FontWeight.SemiBold), maxLines = 1, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }
    }
}
