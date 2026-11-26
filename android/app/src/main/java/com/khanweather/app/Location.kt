package com.khanweather.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.khanweather.core.Coordinate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale

object LocationHelper {
    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** Immediate cached coordinate when permission is granted, so loads don't block on GPS. */
    @SuppressLint("MissingPermission")
    suspend fun cached(context: Context): Coordinate? {
        if (!hasPermission(context)) return null
        val client = LocationServices.getFusedLocationProviderClient(context)
        val loc = withTimeoutOrNull(150) { runCatching { client.lastLocation.await() }.getOrNull() }
        if (loc != null) return Coordinate(loc.latitude, loc.longitude).also { Prefs.lastLocation = it }
        return Prefs.lastLocation
    }

    /** A fresh fix if one comes within 10 seconds, otherwise the last one the phone knows. */
    @SuppressLint("MissingPermission")
    suspend fun current(context: Context): Coordinate? {
        if (!hasPermission(context)) return null
        val client = LocationServices.getFusedLocationProviderClient(context)
        val fresh = withTimeoutOrNull(10_000) {
            runCatching {
                client.getCurrentLocation(Priority.PRIORITY_BALANCED_POWER_ACCURACY, CancellationTokenSource().token).await()
            }.getOrNull()
        }
        val loc = fresh ?: runCatching { client.lastLocation.await() }.getOrNull()
            ?: platformLocation(context) ?: return null
        return Coordinate(loc.latitude, loc.longitude).also { Prefs.lastLocation = it }
    }

    /** Without Google Play services (or before it has a fix), ask Android's own location service. */
    @SuppressLint("MissingPermission")
    private suspend fun platformLocation(context: Context): Location? {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.PASSIVE_PROVIDER)
            .filter { runCatching { lm.isProviderEnabled(it) }.getOrDefault(false) }
        providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { System.currentTimeMillis() - it.time < 30 * 60_000 }
            .maxByOrNull { it.time }?.let { return it }
        if (Build.VERSION.SDK_INT >= 30) {
            for (p in providers.filter { it != LocationManager.PASSIVE_PROVIDER }) {
                val found = withTimeoutOrNull(10_000) {
                    suspendCancellableCoroutine<Location?> { cont ->
                        val cancel = CancellationSignal()
                        cont.invokeOnCancellation { cancel.cancel() }
                        lm.getCurrentLocation(p, cancel, context.mainExecutor) { cont.resume(it) }
                    }
                }
                if (found != null) return found
            }
        }
        return providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }.maxByOrNull { it.time }
    }

    /** Last known location without waiting, for widgets and background checks. */
    @SuppressLint("MissingPermission")
    suspend fun lastKnown(context: Context): Coordinate? {
        if (hasPermission(context)) {
            val client = LocationServices.getFusedLocationProviderClient(context)
            val loc = withTimeoutOrNull(8_000) { runCatching { client.lastLocation.await() }.getOrNull() }
            if (loc != null) return Coordinate(loc.latitude, loc.longitude).also { Prefs.lastLocation = it }
        }
        return Prefs.lastLocation
    }
}

/** "Mississauga", "Paris": the town for a coordinate, from the phone's geocoder. */
object PlaceNames {
    @Suppress("DEPRECATION")
    suspend fun name(context: Context, c: Coordinate): String? = withContext(Dispatchers.IO) {
        if (!Geocoder.isPresent()) return@withContext null
        withTimeoutOrNull(8_000) {
            runCatching {
                val a = Geocoder(context, Locale.getDefault()).getFromLocation(c.latitude, c.longitude, 1)?.firstOrNull()
                a?.locality ?: a?.subAdminArea ?: a?.adminArea ?: a?.featureName
            }.getOrNull()
        }
    }
}
