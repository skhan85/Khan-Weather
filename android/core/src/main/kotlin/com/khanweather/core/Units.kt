@file:Suppress("EnumEntryName")

package com.khanweather.core

import java.util.Locale

enum class TemperatureUnit(val label: String) {
    celsius("°C"), fahrenheit("°F");

    /** Converts from °C. */
    fun convert(celsius: Double): Double = if (this == TemperatureUnit.celsius) celsius else celsius * 9 / 5 + 32
}

enum class WindUnit(val label: String) {
    kmh("km/h"), mph("mph"), ms("m/s"), knots("knots");

    fun convert(kmh: Double): Double = when (this) {
        WindUnit.kmh -> kmh
        mph -> kmh / 1.609344
        ms -> kmh / 3.6
        knots -> kmh / 1.852
    }
}

enum class PrecipitationUnit(val label: String) { metric("mm / cm"), inches("inches") }

enum class PressureUnit(val label: String) {
    hPa("hPa"), kPa("kPa"), inHg("inHg");

    fun convert(hPa: Double): Double = when (this) {
        PressureUnit.hPa -> hPa
        kPa -> hPa / 10
        inHg -> hPa * 0.0295299830714
    }
}

enum class DistanceUnit(val label: String) {
    km("km"), mi("miles");

    fun convert(km: Double): Double = if (this == DistanceUnit.km) km else km / 1.609344
}

/** The user's unit choices. The app keeps `current` in step with its settings. */
data class UnitSettings(
    val temperature: TemperatureUnit = TemperatureUnit.celsius,
    val wind: WindUnit = WindUnit.kmh,
    val precipitation: PrecipitationUnit = PrecipitationUnit.metric,
    val pressure: PressureUnit = PressureUnit.kPa,
    val distance: DistanceUnit = DistanceUnit.km,
) {
    companion object {
        @Volatile
        var current: UnitSettings = UnitSettings()
    }
}

object WeatherFormat {
    /** "21°" style, rounded to whole degrees. Takes °C and shows it in the user's unit. */
    fun temperature(value: Double?, unit: TemperatureUnit = UnitSettings.current.temperature): String {
        if (value == null) return "--"
        val whole = unit.convert(value).rndInt()
        return "${if (whole == 0) 0 else whole}°"
    }

    /** Takes km/h: "12 km/h", "7 mph". */
    fun wind(kmh: Double?, unit: WindUnit = UnitSettings.current.wind): String {
        if (kmh == null) return "--"
        return "${unit.convert(kmh).rndInt()} ${unit.label}"
    }

    fun percent(value: Double?): String = if (value == null) "--" else "${value.rndInt()}%"

    /** Wind chill and humidex are both shown as plain "Feels like" (Saad, 2026-11-15). */
    @Suppress("UNUSED_PARAMETER")
    fun feelsLikeLabel(kind: FeelsLikeKind): String = "Feels like"

    /** "CR-27 Campbellville" -> "Campbellville". */
    fun plainStationName(name: String): String {
        val trimmed = name.replace(Regex("^[A-Z]{1,4}-?\\d+[A-Z]?\\s+"), "")
        return trimmed.ifEmpty { name }
    }

    /** "3 home weather stations about 3 km away" or "Toronto Pearson, about 25 km away". */
    fun readingSource(o: Observation): String {
        val place = if (o.dataProvider == "NETATMO") {
            val n = o.stationName.takeWhile { it.isDigit() }.toIntOrNull() ?: 1
            if (n > 1) "$n home weather stations" else "a home weather station"
        } else {
            plainStationName(o.stationName) + ","
        }
        val km = o.distanceKm ?: return place.trim(',')
        if (km < 1) return place.trim(',') + " under 1 km away"
        return place + " about " + (distance(km.rnd()) ?: "") + " away"
    }

    /** 8-point compass for the direction the wind comes from: "NW". */
    fun compass(degrees: Double?): String? {
        if (degrees == null) return null
        val names = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")
        val i = ((((degrees % 360) + 360) % 360) / 45).rndInt() % 8
        return names[i]
    }

    /** Takes hPa: "101.3 kPa", "1013 hPa", "29.92 inHg". */
    fun pressure(hPa: Double?, unit: PressureUnit = UnitSettings.current.pressure): String? {
        if (hPa == null) return null
        val v = unit.convert(hPa)
        return when (unit) {
            PressureUnit.hPa -> "${v.rndInt()} hPa"
            PressureUnit.kPa -> String.format(Locale.US, "%.1f kPa", v)
            PressureUnit.inHg -> String.format(Locale.US, "%.2f inHg", v)
        }
    }

    /** Takes km: "13 km", "0.4 miles". One decimal under 10. */
    fun distance(km: Double?, unit: DistanceUnit = UnitSettings.current.distance): String? {
        if (km == null) return null
        val v = unit.convert(km)
        return if (v >= 10 || v == v.rnd()) "${v.rndInt()} ${unit.label}"
        else String.format(Locale.US, "%.1f %s", v, unit.label)
    }

    /** "Low", "Moderate", "High", "Very high", "Extreme" (WHO UV index bands). */
    fun uvLevel(uv: Double?): String? {
        if (uv == null) return null
        val level = when {
            uv < 3 -> "Low"
            uv < 6 -> "Moderate"
            uv < 8 -> "High"
            uv < 11 -> "Very high"
            else -> "Extreme"
        }
        return "${uv.rndInt()} $level"
    }

    /** "3 mm", "2 cm", or "2 cm, 3 mm" for a day's totals; null when there's less than 0.5 of either. */
    fun precipitationTotals(rainMm: Double?, snowCm: Double?,
                            unit: PrecipitationUnit = UnitSettings.current.precipitation): String? {
        val parts = mutableListOf<String>()
        if (unit == PrecipitationUnit.inches) {
            if (snowCm != null && snowCm >= 0.5) parts.add(inches(snowCm / 2.54) + " snow")
            if (rainMm != null && rainMm >= 0.5) parts.add(inches(rainMm / 25.4))
        } else {
            if (snowCm != null && snowCm >= 0.5) parts.add("${maxOf(1, snowCm.rndInt())} cm")
            if (rainMm != null && rainMm >= 0.5) parts.add("${maxOf(1, rainMm.rndInt())} mm")
        }
        return if (parts.isEmpty()) null else parts.joinToString(", ")
    }

    private fun inches(value: Double): String =
        String.format(Locale.US, "%.1f in", maxOf(0.1, (value * 10).rnd() / 10))
}
