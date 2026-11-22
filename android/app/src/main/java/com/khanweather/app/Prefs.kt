package com.khanweather.app

import android.content.Context
import android.content.SharedPreferences
import com.khanweather.core.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Settings, saved places and small remembered values, in SharedPreferences. */
object Prefs {
    private lateinit var sp: SharedPreferences
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun init(context: Context) {
        if (!::sp.isInitialized) sp = context.applicationContext.getSharedPreferences("khanweather", Context.MODE_PRIVATE)
        applyUnits()
    }

    val prefs: SharedPreferences get() = sp

    // Units
    var temperatureUnit: TemperatureUnit
        get() = enumOr(sp.getString("temperatureUnit", null), TemperatureUnit.celsius)
        set(v) { sp.edit().putString("temperatureUnit", v.name).apply(); applyUnits() }
    var windUnit: WindUnit
        get() = enumOr(sp.getString("windUnit", null), WindUnit.kmh)
        set(v) { sp.edit().putString("windUnit", v.name).apply(); applyUnits() }
    var precipitationUnit: PrecipitationUnit
        get() = enumOr(sp.getString("precipitationUnit", null), PrecipitationUnit.metric)
        set(v) { sp.edit().putString("precipitationUnit", v.name).apply(); applyUnits() }
    var pressureUnit: PressureUnit
        get() = enumOr(sp.getString("pressureUnit", null), PressureUnit.kPa)
        set(v) { sp.edit().putString("pressureUnit", v.name).apply(); applyUnits() }
    var distanceUnit: DistanceUnit
        get() = enumOr(sp.getString("distanceUnit", null), DistanceUnit.km)
        set(v) { sp.edit().putString("distanceUnit", v.name).apply(); applyUnits() }

    /** Set once the person has picked units (the first-launch question). */
    var unitsChosen: Boolean
        get() = sp.getBoolean("unitsChosen", false)
        set(v) = sp.edit().putBoolean("unitsChosen", v).apply()

    /** Whether any unit was ever saved (someone updating from a version without the question). */
    val hasSavedUnits: Boolean
        get() = listOf("temperatureUnit", "windUnit", "precipitationUnit", "pressureUnit", "distanceUnit").any { sp.contains(it) }

    val units: UnitSettings get() = UnitSettings(temperatureUnit, windUnit, precipitationUnit, pressureUnit, distanceUnit)

    /** Sets all five units at once. */
    fun saveUnits(u: UnitSettings) {
        sp.edit().putString("temperatureUnit", u.temperature.name).putString("windUnit", u.wind.name)
            .putString("precipitationUnit", u.precipitation.name).putString("pressureUnit", u.pressure.name)
            .putString("distanceUnit", u.distance.name).apply()
        applyUnits()
    }

    fun applyUnits() {
        if (!::sp.isInitialized) return
        UnitSettings.current = UnitSettings(temperatureUnit, windUnit, precipitationUnit, pressureUnit, distanceUnit)
    }

    // Display
    var clock: String
        get() = sp.getString("clockStyle", "automatic")!!
        set(v) = sp.edit().putString("clockStyle", v).apply()
    var appearance: String
        get() = sp.getString("appearance", "system")!!
        set(v) = sp.edit().putString("appearance", v).apply()
    var feelsLikeFirst: Boolean
        get() = sp.getString("mainTemperature", "actual") == "feelsLike"
        set(v) = sp.edit().putString("mainTemperature", if (v) "feelsLike" else "actual").apply()
    var hourlyCount: Int
        get() = sp.getInt("hourlyCount", 24)
        set(v) = sp.edit().putInt("hourlyCount", v).apply()
    var showDetails: Boolean
        get() = sp.getBoolean("showTodayDetails", true)
        set(v) = sp.edit().putBoolean("showTodayDetails", v).apply()
    var showAirQuality: Boolean
        get() = sp.getBoolean("showAirQuality", true)
        set(v) = sp.edit().putBoolean("showAirQuality", v).apply()
    var hyperlocal: Boolean
        get() = sp.getBoolean("useHyperlocalPWS", ObservationSource.hyperlocalDefault)
        set(v) = sp.edit().putBoolean("useHyperlocalPWS", v).apply()

    // Notifications
    var alertNotifications: Boolean
        get() = sp.getBoolean("alertNotifications", false)
        set(v) = sp.edit().putBoolean("alertNotifications", v).apply()
    var advisoryNotifications: Boolean
        get() = sp.getBoolean("alertNotificationsAdvisories", false)
        set(v) = sp.edit().putBoolean("alertNotificationsAdvisories", v).apply()
    var rainNotifications: Boolean
        get() = sp.getBoolean("rainNotifications", false)
        set(v) = sp.edit().putBoolean("rainNotifications", v).apply()
    var frostNotifications: Boolean
        get() = sp.getBoolean("frostNotifications", false)
        set(v) = sp.edit().putBoolean("frostNotifications", v).apply()

    // Places
    var places: List<SavedPlace>
        get() = sp.getString("savedPlaces", null)?.let {
            runCatching { json.decodeFromString(ListSerializer(SavedPlace.serializer()), it) }.getOrNull()
        } ?: emptyList()
        set(v) = sp.edit().putString("savedPlaces", json.encodeToString(ListSerializer(SavedPlace.serializer()), v)).apply()
    var selectedPlaceId: String?
        get() = sp.getString("selectedPlace", null)
        set(v) = sp.edit().putString("selectedPlace", v).apply()

    /** Where "current location" last was, for background checks and widgets. */
    var lastLocation: Coordinate?
        get() {
            val lat = sp.getString("lastLat", null)?.toDoubleOrNull() ?: return null
            val lon = sp.getString("lastLon", null)?.toDoubleOrNull() ?: return null
            return Coordinate(lat, lon)
        }
        set(v) {
            if (v == null) return
            sp.edit().putString("lastLat", v.latitude.toString()).putString("lastLon", v.longitude.toString()).apply()
        }

    private inline fun <reified E : Enum<E>> enumOr(name: String?, default: E): E =
        name?.let { n -> enumValues<E>().firstOrNull { it.name == n } } ?: default
}

/** Clock times that follow the 12/24-hour setting. */
object TimeText {
    private fun pattern(p: String, zone: String): DateTimeFormatter =
        DateTimeFormatter.ofPattern(p, Locale.US).withZone(ZoneId.of(zone))

    private fun twelve(): Boolean = when (Prefs.clock) {
        "twelveHour" -> true
        "twentyFourHour" -> false
        else -> !is24hSystem
    }

    @Volatile var is24hSystem = false

    private fun fix(s: String) = s.replace("AM", "am").replace("PM", "pm")

    /** "3 pm" or "15:00". */
    fun hour(t: Epoch, zone: String): String =
        if (twelve()) fix(pattern("h a", zone).format(Instant.ofEpochSecond(t.toLong())))
        else pattern("HH:00", zone).format(Instant.ofEpochSecond(t.toLong()))

    /** "3:42 pm" or "15:42". */
    fun time(t: Epoch, zone: String): String =
        if (twelve()) fix(pattern("h:mm a", zone).format(Instant.ofEpochSecond(t.toLong())))
        else pattern("HH:mm", zone).format(Instant.ofEpochSecond(t.toLong()))

    fun format(t: Epoch, zone: String, p: String): String = fix(pattern(p, zone).format(Instant.ofEpochSecond(t.toLong())))

    /** "Mon" */
    fun weekdayShort(t: Epoch, zone: String) = format(t, zone, "EEE")
    /** "Monday" */
    fun weekday(t: Epoch, zone: String) = format(t, zone, "EEEE")
    /** "Monday 3 pm" */
    fun weekdayHour(t: Epoch, zone: String) = weekday(t, zone) + " " + hour(t, zone)
    /** "Monday, Nov 24" */
    fun weekdayMonthDay(t: Epoch, zone: String) = format(t, zone, "EEEE, MMM d")
    /** "Mon 3:42 pm" */
    fun weekdayTime(t: Epoch, zone: String) = weekdayShort(t, zone) + " " + time(t, zone)
}
