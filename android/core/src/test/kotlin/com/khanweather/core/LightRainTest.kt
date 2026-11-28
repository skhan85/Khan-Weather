package com.khanweather.core

import kotlin.test.*

/** More ways to tell it's drizzling or raining lightly when the radar shows nothing (27 Nov 2026, Milton). */
class LightRainTest {
    private val milton = Coordinate(43.513, -79.882)
    private val now = nowEpoch()

    private fun forecast(t: Double, rh: Double?) = Forecast(milton, "America/Toronto",
        CurrentConditions(now, t, t, FeelsLikeKind.apparent, humidity = rh, condition = WeatherCondition.overcast, isDay = false),
        emptyList(), emptyList(), "t", now).apply {
        val start = kotlin.math.floor(now / 900) * 900
        minutely = (0 until 8).map { PrecipitationSlot(start + it * 900, 0.0) }
    }

    @Test fun twoNearbyRainReportsUnderADryRadarMeanDrizzle() {
        val o = Observation("3 Netatmo stations", now, 5.0, distanceKm = 2.0)
        o.noteDrizzle("Hamilton Airport", 26.0, WeatherCondition.rain, now, now)
        val f = forecast(5.0, 92.0).apply { observation = o }
        assertEquals(WeatherCondition.overcast, f.agreeingNowWithNowcast(now).current.condition)
        o.noteDrizzle("Toronto Pearson", 30.0, WeatherCondition.rain, now, now)
        o.noteDrizzle("Toronto Pearson", 30.0, WeatherCondition.rain, now, now)
        assertEquals(2, o.nearbyWetStations?.size)
        val shown = f.agreeingNowWithNowcast(now)
        assertEquals(WeatherCondition.drizzle, shown.current.condition)
        assertEquals(Nowcast.Kind.rain, shown.nowcast(now)?.kind)
        val drier = forecast(5.0, 84.0).apply { observation = o }
        assertEquals(WeatherCondition.overcast, drier.agreeingNowWithNowcast(now).current.condition)
        val snow = Observation("x", now, 0.0, distanceKm = 2.0)
        snow.noteDrizzle("A", 20.0, WeatherCondition.snow, now, now)
        snow.noteDrizzle("B", 20.0, WeatherCondition.rain, now - 7200, now)
        assertNull(snow.nearbyWetStations)
    }

    @Test fun mostModelsWetNowInDampAirMeansDrizzle() {
        fun f(t: Double, rh: Double, wet: Int) = forecast(t, rh).apply {
            hourly = listOf(HourlyForecast(now - 900, t, condition = WeatherCondition.overcast).apply { modelCount = 6; modelsWet = wet })
        }
        assertEquals(WeatherCondition.drizzle, f(6.0, 93.0, 4).agreeingNowWithNowcast(now).current.condition)
        assertEquals(WeatherCondition.overcast, f(6.0, 93.0, 2).agreeingNowWithNowcast(now).current.condition)
        assertEquals(WeatherCondition.overcast, f(6.0, 85.0, 4).agreeingNowWithNowcast(now).current.condition)
        assertEquals(WeatherCondition.overcast, f(0.5, 93.0, 4).agreeingNowWithNowcast(now).current.condition)
    }

    @Test fun lightEchoCountsInSaturatedAir() {
        val light = RadarNow(0.3, 0.0, now)
        assertEquals(WeatherCondition.drizzle, forecast(6.0, 95.0).applyingRadar(light).current.condition)
        val dry = forecast(6.0, 80.0).applyingRadar(light)
        assertEquals(WeatherCondition.overcast, dry.current.condition)
        assertNull(dry.radar)
    }

    @Test fun metarNotesRainAtOtherAirports() {
        val json = """
        [{"icaoId":"KLGA","name":"New York/La Guardia Arpt, NY, US","lat":40.7794,"lon":-73.8803,"obsTime":1794578460,
          "temp":8.9,"dewp":8.1,"wdir":300,"wspd":12,"visib":"10+","wxString":"BR","cover":"OVC"},
         {"icaoId":"KJFK","name":"New York/JF Kennedy Intl, NY, US","lat":40.6392,"lon":-73.7639,"obsTime":1794578460,
          "temp":9.4,"dewp":8.2,"wdir":"VRB","wspd":3,"visib":6,"wxString":"-RA","cover":"OVC"},
         {"icaoId":"KEWR","name":"Newark Liberty Intl, NJ, US","lat":40.6925,"lon":-74.1687,"obsTime":1794578460,
          "temp":9.0,"dewp":8.0,"wdir":200,"wspd":5,"visib":5,"wxString":"-DZ BR","cover":"OVC"}]
        """.toByteArray()
        val o = assertNotNull(METARProvider.parse(json, Coordinate(40.75, -73.9), 1794578460.0 + 600))
        assertEquals("New York/La Guardia Arpt", o.stationName)
        assertEquals(2, o.nearbyWetStations?.size)
        assertNotNull(o.nearbyDrizzleStation)
    }

    /** 27 Nov, 7:48 pm in Mississauga: Pearson (9 km) said light rain, 92% here, radar dry, drizzling. */
    @Test fun nearbyStationRainInSaturatedAirSurvivesADryRadar() {
        fun f(rh: Double, km: Double) = forecast(4.0, rh).apply {
            current.condition = WeatherCondition.rain
            observation = Observation("3 Netatmo stations", now, 4.0, condition = WeatherCondition.rain,
                conditionText = "Light Rain", distanceKm = 3.0).apply {
                skyStationName = "Toronto Pearson Int'l Airport"; skyDistanceKm = km
            }
        }
        val dryRadar = RadarNow(0.0, 0.0, now)
        val shown = f(92.0, 9.0).applyingRadar(dryRadar).agreeingNowWithNowcast(now)
        assertEquals(WeatherCondition.drizzle, shown.current.condition)
        assertTrue(shown.skySource?.contains("Toronto Pearson") == true)
        assertEquals(Nowcast.Kind.rain, shown.nowcast(now)?.kind)
        assertEquals(WeatherCondition.overcast, f(86.0, 9.0).applyingRadar(dryRadar).current.condition)
        assertEquals(WeatherCondition.overcast, f(92.0, 30.0).applyingRadar(dryRadar).current.condition)
    }
}
