package com.khanweather.core

import kotlin.test.*

class UnitPresetTest {
    @Test fun presets() {
        assertEquals(UnitSettings(TemperatureUnit.fahrenheit, WindUnit.mph, PrecipitationUnit.inches, PressureUnit.inHg, DistanceUnit.mi), UnitPreset.us.settings)
        assertEquals(UnitSettings(), UnitPreset.canadian.settings)
        assertEquals(PressureUnit.mb, UnitPreset.uk.settings.pressure)
        assertEquals(UnitPreset.canadian, UnitSettings().preset)
        assertNull(UnitSettings(temperature = TemperatureUnit.fahrenheit).preset)
        assertEquals(UnitPreset.us, UnitPreset.forRegion("US"))
        assertEquals(UnitPreset.uk, UnitPreset.forRegion("gb"))
        assertEquals(UnitPreset.canadian, UnitPreset.forRegion("CA"))
        assertEquals(UnitPreset.canadian, UnitPreset.forRegion(null))
        assertEquals("1013 mb", WeatherFormat.pressure(1013.25, PressureUnit.mb))
        assertEquals("°C · mph · mm · mi · mb", UnitPreset.uk.detail)
    }

    @Test fun distances() {
        assertEquals("13 km", WeatherFormat.distance(13.4, DistanceUnit.km))
        assertEquals("740 m", WeatherFormat.distance(0.74, DistanceUnit.km))
        assertEquals("1 m", WeatherFormat.distance(0.001, DistanceUnit.km))
        assertEquals("0.9 miles", WeatherFormat.distance(1.5, DistanceUnit.mi))
        assertEquals("260 ft", WeatherFormat.distance(0.08, DistanceUnit.mi))
        assertEquals("3 km", WeatherFormat.roughDistance(2.9, DistanceUnit.km))
        assertEquals("400 m", WeatherFormat.roughDistance(0.44, DistanceUnit.km))
        assertEquals("1 m", WeatherFormat.roughDistance(0.004, DistanceUnit.km))
        assertEquals("1.2 miles", WeatherFormat.roughDistance(2.0, DistanceUnit.mi))
        assertEquals("1 mile", WeatherFormat.roughDistance(1.6, DistanceUnit.mi))
        assertEquals("16 miles", WeatherFormat.roughDistance(25.2, DistanceUnit.mi))
        assertEquals("200 ft", WeatherFormat.roughDistance(0.05, DistanceUnit.mi))
        assertEquals("0.4 mm", WeatherFormat.rainAmount(0.4, PrecipitationUnit.metric))
        assertEquals("0.10 in", WeatherFormat.rainAmount(2.54, PrecipitationUnit.inches))
    }

    @Test fun alertTextGetsThePersonsUnits() {
        val us = UnitPreset.us.settings
        assertEquals("Rainfall amounts of 50 to 75 mm (2 to 3 in) are expected.",
            AlertText.withUnits("Rainfall amounts of 50 to 75 mm are expected.", us))
        assertEquals("Gusts up to 90 km/h (56 mph) and 15 cm (6 in) of snow.",
            AlertText.withUnits("Gusts up to 90 km/h and 15 cm of snow.", us))
        assertEquals("Wind chill near -35°C (-31°F).", AlertText.withUnits("Wind chill near -35°C.", us))
        assertEquals("Up to 6 inches (152 mm) of snow, winds 40 mph (64 km/h).",
            AlertText.withUnits("Up to 6 inches of snow, winds 40 mph.", UnitSettings()))
        assertEquals("Gusts up to 90 km/h (56 mph).", AlertText.withUnits("Gusts up to 90 km/h.", UnitPreset.uk.settings))
        assertEquals("Rainfall amounts of 50 mm and gusts of 90 km/h.",
            AlertText.withUnits("Rainfall amounts of 50 mm and gusts of 90 km/h.", UnitSettings()))
        assertEquals(listOf("Gusts up to 90 km/h (56 mph)."), AlertText.paragraphs("Gusts up to 90 km/h.", us))
    }
}
