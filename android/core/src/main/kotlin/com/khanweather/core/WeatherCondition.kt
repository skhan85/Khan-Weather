@file:Suppress("EnumEntryName")

package com.khanweather.core

import kotlinx.serialization.Serializable

/** Provider-neutral sky/precipitation state. Names match the iOS raw values exactly. */
@Serializable
enum class WeatherCondition {
    clear, mainlyClear, partlyCloudy, overcast, fog,
    /** More cloud than sky: "Mostly Cloudy", a METAR's BKN layer. */
    mostlyCloudy,
    drizzle, freezingDrizzle, rain, freezingRain,
    snow, snowGrains, rainShowers, snowShowers,
    thunderstorm, thunderstormHail,
    unknown;

    val description: String
        get() = when (this) {
            clear -> "Clear"
            mainlyClear -> "Mainly clear"
            partlyCloudy -> "Partly cloudy"
            mostlyCloudy -> "Mostly cloudy"
            overcast -> "Overcast"
            fog -> "Fog"
            drizzle -> "Drizzle"
            freezingDrizzle -> "Freezing drizzle"
            rain -> "Rain"
            freezingRain -> "Freezing rain"
            snow -> "Snow"
            snowGrains -> "Snow grains"
            rainShowers -> "Rain showers"
            snowShowers -> "Snow showers"
            thunderstorm -> "Thunderstorm"
            thunderstormHail -> "Thunderstorm with hail"
            unknown -> "Unknown"
        }

    /** Rain, drizzle and showers, but not snow (which radar and home gauges can miss). */
    val isRainLike: Boolean
        get() = this == drizzle || this == freezingDrizzle || this == rain || this == freezingRain || this == rainShowers

    /** Rain, snow, drizzle and the like, but not thunderstorms. */
    val isPrecipitation: Boolean
        get() = when (this) {
            drizzle, freezingDrizzle, rain, freezingRain, snow, snowGrains, rainShowers, snowShowers -> true
            else -> false
        }

    val isWetOrStorm: Boolean get() = isPrecipitation || this == thunderstorm || this == thunderstormHail

    /**
     * The model sometimes flags a stray flurry or sprinkle that barely registers. When the amount
     * is a trace and the chance is low, show cloud instead. Needs a known amount.
     */
    fun ignoringTrace(probability: Double?, amountMm: Double?): WeatherCondition {
        if (!isPrecipitation || amountMm == null || amountMm >= 0.2 || (probability ?: 0.0) >= 20) return this
        return overcast
    }

    /** The same kind of weather as rain or as snow. Freezing rain, storms and dry skies stay. */
    fun converted(type: PrecipitationKind): WeatherCondition = when {
        (this == rain || this == drizzle) && type == PrecipitationKind.snow -> snow
        this == rainShowers && type == PrecipitationKind.snow -> snowShowers
        (this == snow || this == snowGrains) && type == PrecipitationKind.rain -> rain
        this == snowShowers && type == PrecipitationKind.rain -> rainShowers
        else -> this
    }

    companion object {
        /** WMO weather interpretation codes, as used by Open-Meteo. */
        fun fromWmo(code: Int?): WeatherCondition = when (code) {
            0 -> clear
            1 -> mainlyClear
            2 -> partlyCloudy
            3 -> overcast
            45, 48 -> fog
            51, 53, 55 -> drizzle
            56, 57 -> freezingDrizzle
            61, 63, 65 -> rain
            66, 67 -> freezingRain
            71, 73, 75 -> snow
            77 -> snowGrains
            80, 81, 82 -> rainShowers
            85, 86 -> snowShowers
            95 -> thunderstorm
            96, 99 -> thunderstormHail
            else -> unknown
        }

        /** From words like "Light Rain and Fog/Mist" or "Mostly Cloudy" (NWS). */
        fun fromText(text: String?): WeatherCondition? {
            val t = text?.lowercase() ?: return null
            if (t.isEmpty()) return null
            return when {
                t.contains("thunder") -> thunderstorm
                t.contains("freezing rain") -> freezingRain
                t.contains("freezing drizzle") -> freezingDrizzle
                t.contains("snow") || t.contains("sleet") -> snow
                t.contains("drizzle") -> drizzle
                t.contains("shower") -> rainShowers
                t.contains("rain") -> rain
                t.contains("fog") || t.contains("mist") || t.contains("haze") -> fog
                t.contains("mostly cloudy") || t.contains("considerable cloud") -> mostlyCloudy
                t.contains("overcast") || t == "cloudy" -> overcast
                t.contains("partly") || t.contains("cloud") -> partlyCloudy
                t.contains("clear") || t.contains("sunny") || t.contains("fair") -> clear
                else -> null
            }
        }

        /** From METAR present weather ("-RA BR") and cloud cover ("OVC"). */
        fun fromMetar(wx: String?, cover: String?): WeatherCondition? {
            val w = wx ?: ""
            return when {
                w.contains("TS") -> thunderstorm
                w.contains("FZRA") -> freezingRain
                w.contains("FZDZ") -> freezingDrizzle
                w.contains("SN") || w.contains("SG") || w.contains("PL") -> snow
                w.contains("SHRA") -> rainShowers
                w.contains("RA") -> rain
                w.contains("DZ") -> drizzle
                w.contains("FG") || w.contains("BR") || w.contains("HZ") -> fog
                else -> when (cover?.uppercase()) {
                    "SKC", "CLR", "CAVOK", "NSC", "NCD" -> clear
                    "FEW" -> mainlyClear
                    "SCT" -> partlyCloudy
                    "BKN" -> mostlyCloudy
                    "OVC", "OVX" -> overcast
                    else -> null
                }
            }
        }
    }
}

/** Rain, snow, or either, so a "40%" can say what it's a chance of. */
@Serializable
enum class PrecipitationKind {
    rain, snow, mixed;

    /** "rain", "snow", "rain or snow". */
    val noun: String
        get() = when (this) {
            rain -> "rain"
            snow -> "snow"
            mixed -> "rain or snow"
        }

    companion object {
        /** Uses forecast amounts when there are any, then the condition, then temperature. */
        fun guess(rain: Double?, snow: Double?, condition: WeatherCondition, low: Double, high: Double): PrecipitationKind {
            val r = rain ?: 0.0
            val s = snow ?: 0.0
            if (r > 0 && s > 0) return mixed
            if (s > 0) return PrecipitationKind.snow
            if (r > 0) return PrecipitationKind.rain
            when (condition) {
                WeatherCondition.snow, WeatherCondition.snowGrains, WeatherCondition.snowShowers -> return PrecipitationKind.snow
                WeatherCondition.freezingRain, WeatherCondition.freezingDrizzle -> return mixed
                WeatherCondition.rain, WeatherCondition.rainShowers, WeatherCondition.drizzle,
                WeatherCondition.thunderstorm, WeatherCondition.thunderstormHail -> return PrecipitationKind.rain
                else -> {}
            }
            if (high <= 1) return PrecipitationKind.snow
            if (low >= 3) return PrecipitationKind.rain
            return mixed
        }
    }
}

@Serializable
enum class FeelsLikeKind { apparent, humidex, windChill }

enum class ForecastConfidence(val label: String) {
    sure("Models agree"), fair("Models mostly agree"), unsure("Models disagree")
}
