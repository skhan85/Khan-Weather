package com.khanweather.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.khanweather.app.widget.Widgets
import com.khanweather.core.*
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

sealed class LoadState {
    data object Loading : LoadState()
    data class Loaded(val forecast: Forecast) : LoadState()
    data class Failed(val message: String) : LoadState()
}

/**
 * Loads the forecast for the current location or a saved place, in the same order as the iPhone
 * app: the model forecast shows first, then the station reading, radar, alerts and air quality
 * fill in as each answers.
 */
class WeatherViewModel(app: Application) : AndroidViewModel(app) {
    var state by mutableStateOf<LoadState>(LoadState.Loading); private set
    var usingFallbackLocation by mutableStateOf(false); private set
    var placeName by mutableStateOf<String?>(null); private set
    var alerts by mutableStateOf<List<WeatherAlert>>(emptyList()); private set
    var airQuality by mutableStateOf<AirQuality?>(null); private set
    var normals by mutableStateOf<ClimateNormals?>(null); private set
    var refreshing by mutableStateOf(false); private set
    var lastReload = 0.0; private set

    private var generation = 0
    private var lastPlaceKey: String? = "unset"
    private val cache = mutableMapOf<String?, Snapshot>()
    private val cacheAge = 45 * 60.0

    private val context get() = getApplication<Application>()

    fun reload(place: SavedPlace?) {
        lastReload = nowEpoch()
        viewModelScope.launch {
            refreshing = true
            try { refresh(place) } finally { refreshing = false }
            val s = state
            if (s is LoadState.Loaded) {
                Notifier.markSeen(alerts)
                if (place == null) {
                    Notifier.markRainSeen(s.forecast.nowcast())
                    Widgets.updateAll(context)
                }
                prefetch(Prefs.places)
            }
        }
    }

    private suspend fun refresh(place: SavedPlace?, allowLocationFollowUp: Boolean = true): Unit = coroutineScope {
        generation += 1
        val gen = generation
        val key = place?.id
        var showingStaleDiskCache = false
        if (lastPlaceKey != key) {
            lastPlaceKey = key
            val memSnap = cache[key]?.takeIf { nowEpoch() - it.savedAt < cacheAge }
            val snap = memSnap ?: SnapshotStore.load(context, key, maxAge = 2 * 3600.0)?.let { disk ->
                showingStaleDiskCache = true
                val f = if (nowEpoch() - disk.forecast.fetchedAt < cacheAge) disk.forecast else disk.forecast.rolledForward()
                disk.copy(forecast = with(WeatherLoader) { f.calibratingEnsemblePop() })
            }
            if (snap != null) {
                state = LoadState.Loaded(snap.forecast)
                placeName = snap.placeName; alerts = snap.alerts; airQuality = snap.airQuality
            } else {
                state = LoadState.Loading
                placeName = place?.name; alerts = emptyList(); airQuality = null
            }
        }
        val target: Coordinate
        val freshCoordTask = if (place == null) {
            val cached = LocationHelper.cached(context)
            if (cached != null) {
                target = cached
                usingFallbackLocation = false
                if (allowLocationFollowUp) async { LocationHelper.current(context) } else null
            } else {
                val c = LocationHelper.current(context)
                if (gen != generation) return@coroutineScope
                usingFallbackLocation = c == null
                target = c ?: Coordinate.fallback
                null
            }
        } else {
            target = place.coordinate
            usingFallbackLocation = false
            null
        }
        val fallbackName = if (usingFallbackLocation) "Toronto" else null

        val knownTemp = ObservationMemory.last(target)?.temperature ?: cache[key]?.forecast?.current?.temperature
        val likelyCold = knownTemp?.let { it <= 4.0 } ?: (kotlin.math.abs(target.latitude) >= 25.0)

        val nameTask = async { place?.name ?: PlaceNames.name(context, target) }
        val observedTask = async { WeatherLoader.observation(target) }
        val radarTask = async { WeatherLoader.radar(target) }
        val nowcastTask = async { WeatherLoader.radarNowcast(target, cold = likelyCold) }
        val weightsTask = async { WeatherLoader.regionalWeights(target) }
        val googleTask = async { WeatherLoader.googleHourly(target) }
        val alertsTask = async { WeatherLoader.alerts(target) }
        val normalsTask = async { WeatherLoader.normals(context, target) }

        val base = try {
            WeatherLoader.forecastProvider.forecast(
                target,
                regionalWeights = { weightsTask.await() },
            ) { withTimeoutOrNull(1500) { observedTask.await()?.blendAnchor } }
        } catch (e: Exception) {
            if (gen != generation) return@coroutineScope
            if (state is LoadState.Loaded) return@coroutineScope
            val cached = SnapshotStore.load(context, key)
            if (cached != null) {
                state = LoadState.Loaded(cached.forecast.rolledForward())
                placeName = cached.placeName; alerts = cached.alerts
                return@coroutineScope
            }
            state = LoadState.Failed(e.message ?: "The forecast service didn't answer.")
            return@coroutineScope
        }
        if (gen != generation) return@coroutineScope
        if (state !is LoadState.Loaded || showingStaleDiskCache) {
            state = LoadState.Loaded(with(WeatherLoader) { base.calibratingEnsemblePop() })
        }
        val airTask = async { WeatherLoader.airQuality(target, base.timeZoneIdentifier) }

        launch {
            val n = nameTask.await() ?: fallbackName
            if (gen == generation && (n != null || placeName == null)) placeName = n
        }
        launch { val a = alertsTask.await(); if (a != null && gen == generation) alerts = a }
        launch { val a = airTask.await(); if (a != null && gen == generation) airQuality = a }
        launch { val n = normalsTask.await(); if (n != null && gen == generation) normals = n }
        val observed = observedTask.await()
        if (gen != generation) return@coroutineScope
        if (observed != null) {
            ObservationMemory.remember(target, observed)
            state = LoadState.Loaded(with(WeatherLoader) { base.applying(observed).calibratingEnsemblePop() })
        }
        val googleHourly = googleTask.await()
        if (gen != generation) return@coroutineScope
        if (googleHourly != null) {
            state = LoadState.Loaded(with(WeatherLoader) {
                base.applyingGoogleHourly(googleHourly).applying(observed).calibratingEnsemblePop()
            })
        }
        val radar = radarTask.await()
        val radarNowcast = nowcastTask.await()
        if (gen != generation) return@coroutineScope
        val loaded = with(WeatherLoader) {
            base.applyingGoogleHourly(googleHourly).applying(observed).applyingRadar(radar).applyingRadarNowcast(radarNowcast).calibratingEnsemblePop()
        }
        state = LoadState.Loaded(loaded)
        // Keep score of the models for where the user actually is, not saved places.
        if (place == null && !usingFallbackLocation) launch { runCatching { AccuracyTracker.update(loaded) } }
        // Wait for the rest, then keep a copy.
        nameTask.await(); alertsTask.await(); airTask.await()
        delay(50)
        if (gen != generation) return@coroutineScope
        val shown = (state as? LoadState.Loaded)?.forecast ?: return@coroutineScope
        val snap = Snapshot(shown, placeName, alerts, airQuality, nowEpoch(), !usingFallbackLocation)
        cache[key] = snap
        SnapshotStore.save(context, key, snap)
        val fresh = freshCoordTask?.await()
        if (fresh != null && gen == generation && distanceKm(target, fresh) > 1.5) {
            refresh(null, allowLocationFollowUp = false)
        }
    }

    /** Fetches saved places in the background so the first switch to each one is quick. */
    private suspend fun prefetch(places: List<SavedPlace>) {
        for (place in places.take(3)) {
            val existing = cache[place.id]
            if (existing != null && nowEpoch() - existing.savedAt < cacheAge / 2) continue
            delay(600)
            val target = place.coordinate
            val snap = runCatching {
                coroutineScope {
                    val obs = async { WeatherLoader.observation(target) }
                    val radar = async { WeatherLoader.radar(target) }
                    val al = async { WeatherLoader.alerts(target) }
                    val f = WeatherLoader.full(target, obs.await(), radar.await())
                    val air = WeatherLoader.airQuality(target, f.timeZoneIdentifier)
                    Snapshot(f, place.name, al.await() ?: emptyList(), air, nowEpoch())
                }
            }.getOrNull() ?: continue
            val now = cache[place.id]
            if (now != null && now.savedAt > snap.savedAt) continue
            cache[place.id] = snap
        }
    }
}
