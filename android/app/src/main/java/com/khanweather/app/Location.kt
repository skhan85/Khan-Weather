package com.khanweather.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
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
        val loc = fresh ?: runCatching { client.lastLocation.await() }.getOrNull() ?: return null
        return Coordinate(loc.latitude, loc.longitude).also { Prefs.lastLocation = it }
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
