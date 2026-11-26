package com.khanweather.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OpenMeteoProviderTest {
    companion object {
        val sample = """
        {
          "latitude": 43.65, "longitude": -79.38, "timezone": "America/Toronto",
          "utc_offset_seconds": -18000,
          "current": {
            "time": 1762956000, "interval": 900,
            "temperature_2m": -2.4, "apparent_temperature": -7.9, "relative_humidity_2m": 81,
            "is_day": 0, "precipitation": 0.1, "weather_code": 71,
            "wind_speed_10m": 19.4, "wind_direction_10m": 280
          },
          "hourly": {
            "time": [1762952400, 1762956000, 1762959600],
            "temperature_2m": [-2.0, -2.4, null],
            "apparent_temperature": [-7.0, -7.9, null],
            "precipitation_probability": [40, 55, 60],
            "weather_code": [3, 71, 73]
          },
          "daily": {
            "time": [1762923600, 1763010000],
            "weather_code": [71, 0],
            "temperature_2m_max": [1.2, 4.0],
            "temperature_2m_min": [-4.1, -3.0],
            "apparent_temperature_max": [-3.0, 0.5],
            "apparent_temperature_min": [-10.2, -8.0],
            "precipitation_probability_max": [80, 5],
            "rain_sum": [1.2, 0], "showers_sum": [0.4, null], "snowfall_sum": [3.1, 0]
          },
          "minutely_15": {
            "time": [1762956000, 1762956900, 1762957800],
            "precipitation": [0.0, 0.3, null],
            "rain": [0.0, 0.0, null],
            "snowfall": [0.0, 0.21, null]
          }
        }
        """.trimIndent()
    }

    private fun parsed() = OpenMeteoProvider.parse(sample.toByteArray(), 0.0)

    @Test fun parsesCurrentConditions() {
        val f = parsed()
        assertEquals("America/Toronto", f.timeZoneIdentifier)
        assertEquals(-2.4, f.current.temperature)
        close(-8.2, f.current.feelsLike, 0.05)
        assertEquals(FeelsLikeKind.windChill, f.current.feelsLikeKind)
        assertEquals(WeatherCondition.snow, f.current.condition)
        assertFalse(f.current.isDay)
        assertEquals(81.0, f.current.humidity)
    }

    @Test fun skipsHoursWithMissingTemperature() {
        val f = parsed()
        assertEquals(2, f.hourly.size)
        assertEquals(55.0, f.hourly.last().precipitationProbability)
    }

    @Test fun parsesDaily() {
        val f = parsed()
        assertEquals(2, f.daily.size)
        assertEquals(1.2, f.daily.first().high)
        assertEquals(-10.2, f.daily.first().feelsLikeLow)
        assertEquals(WeatherCondition.clear, f.daily.last().condition)
        close(1.6, f.daily.first().rainSum, 0.001)
        assertEquals(3.1, f.daily.first().snowfallSum)
        assertEquals(0.0, f.daily.last().rainSum)
    }

    @Test fun parsesMinutely15() {
        val f = parsed()
        assertEquals(2, f.minutely.size)
        assertEquals(0.21, f.minutely.last().snowfall)
        val url = OpenMeteoProvider().url(Coordinate(43.5, -79.9))
        assertTrue(url.contains("minutely_15=precipitation,rain,snowfall"))
        assertTrue(url.contains("snowfall_sum"))
    }

    @Test fun requestUsesRoundedCoordinates() {
        val url = OpenMeteoProvider().url(Coordinate(43.653226, -79.383184))
        assertTrue(url.contains("latitude=43.6532&"))
        assertTrue(url.contains("longitude=-79.3832&"))
        assertTrue(url.contains("timezone=auto"))
    }

    @Test fun httpErrorIsThrown() {
        val p = OpenMeteoProvider(loader = loader { 429 to "" })
        val e = assertFailsWith<HttpStatusException> { sync { p.forecast(Coordinate.fallback) } }
        assertEquals(429, e.code)
    }

    @Test fun northAmericaUsesBlendedTemperatures() {
        val blend = """
        { "hourly": { "time": [1762952400, 1762956000],
                      "temperature_2m_gfs_hrrr": [-5.0, null],
                      "temperature_2m_ecmwf_ifs025": [-3.0, null],
                      "apparent_temperature_gfs_hrrr": [-9.0, null] } }
        """
        val p = OpenMeteoProvider(loader = loader { url -> 200 to (if (url.contains("gem_hrdps_continental")) blend else sample) })
        val f = sync { p.forecast(Coordinate.fallback) }
        // Hours already past use the first day's weights of the spot's region.
        val region = BlendRegion.at(Coordinate.fallback)
        val wHRRR = ModelBlend.weight(WeatherModel.usHighRes, -1.0, region)
        val wECMWF = ModelBlend.weight(WeatherModel.europe, -1.0, region)
        val expected = if (wHRRR + wECMWF > 0) (-5.0 * wHRRR - 3.0 * wECMWF) / (wHRRR + wECMWF) else -4.0
        close(expected, f.hourly[0].temperature, 0.001)
        assertEquals(-9.0, f.hourly[0].feelsLike)
        assertEquals(-5.0, f.hourly[0].modelLow)
        assertEquals(-3.0, f.hourly[0].modelHigh)
        assertEquals(2, f.hourly[0].modelCount)
        assertEquals(2, f.hourly[0].modelsFreezing)
        assertEquals(2.0, f.daily[0].modelSpread)
        assertEquals(ForecastConfidence.sure, f.daily[0].confidence)
        assertEquals(-2.4, f.hourly[1].temperature)
        assertEquals(1.2, f.daily[0].high)
    }

    @Test fun nowComesFromTheBlendBetweenHours() {
        val t0 = 1762952400L
        val temps = OpenMeteoProvider.ModelTemperatures()
        temps.hourly[t0] = OpenMeteoProvider.ModelTemperatures.Hour(4.0, null, 4.0, 4.0, 6, 0, 0)
        temps.hourly[t0 + 3600] = OpenMeteoProvider.ModelTemperatures.Hour(6.0, null, 6.0, 6.0, 6, 0, 0)
        val quarterPast = (t0 + 900).toDouble()
        close(4.5, blendedTemperature(temps, quarterPast), 0.001)
        assertEquals(4.0, blendedTemperature(temps, t0.toDouble()))
        assertNull(blendedTemperature(temps, (t0 + 4500).toDouble()))
        val f = parsed()
        f.current.time = quarterPast
        val b = f.applying(temps)
        close(4.5, b.current.temperature, 0.001)
        assertEquals(FeelsLikeKind.windChill, b.current.feelsLikeKind)
        close(FeelsLike.windChill(4.5, 19.4)!!, b.current.feelsLike, 0.001)
    }

    @Test fun rainOrSnowFromAllTheModels() {
        val m = WeatherModel
        val precip = mapOf(WeatherModel.canada to 1.0, WeatherModel.europe to 0.8, WeatherModel.germany to 0.6,
            WeatherModel.uk to 0.5, WeatherModel.us to 0.4, WeatherModel.europeAI to 0.0)
        val snow = mapOf(WeatherModel.canada to 1.2, WeatherModel.europe to 1.0, WeatherModel.germany to 0.7,
            WeatherModel.uk to 0.0, WeatherModel.us to 0.5, WeatherModel.europeAI to 0.0)
        assertEquals(PrecipitationKind.snow, ModelBlend.precipitationType(0.6, precip, snow))
        assertEquals(PrecipitationKind.rain, ModelBlend.precipitationType(3.2, precip, snow))
        assertEquals(PrecipitationKind.snow, ModelBlend.precipitationType(-2.5, precip, emptyMap()))
        assertEquals(PrecipitationKind.snow, ModelBlend.precipitationType(0.9, emptyMap(), emptyMap()))
        assertEquals(PrecipitationKind.rain, ModelBlend.precipitationType(1.4, emptyMap(), emptyMap()))
        val hour = HourlyForecast(time = 0.0, temperature = 0.6, precipitation = 1.4, condition = WeatherCondition.rainShowers,
            rain = 1.4, snowfall = 0.0)
        hour.setPrecipitationType(PrecipitationKind.snow)
        assertEquals(WeatherCondition.snowShowers, hour.condition)
        assertEquals(0.0, hour.rain)
        close(2.0, hour.snowfall, 0.001)
        assertEquals(PrecipitationKind.snow, hour.precipitationKind)
        hour.setPrecipitationType(PrecipitationKind.rain)
        assertEquals(WeatherCondition.rainShowers, hour.condition)
        close(1.4, hour.rain, 0.001)
        val ice = HourlyForecast(time = 0.0, temperature = -0.5, precipitation = 1.0, condition = WeatherCondition.freezingRain)
        ice.setPrecipitationType(PrecipitationKind.snow)
        assertEquals(WeatherCondition.freezingRain, ice.condition)
        m.hashCode()
    }

    @Test fun feelsLikeFollowsEnvironmentCanada() {
        val chill = FeelsLike.value(0.0, 20.0, -3.0)!!
        assertEquals(FeelsLikeKind.windChill, chill.second)
        close(-5.2, chill.first, 0.1)
        val muggy = FeelsLike.value(25.0, 8.0, 19.0)!!
        assertEquals(FeelsLikeKind.humidex, muggy.second)
        close(31.8, muggy.first, 0.2)
        assertEquals(15.0, FeelsLike.value(15.0, 3.0, 5.0)?.first)
        assertNull(FeelsLike.value(15.0, null, null))
    }

    @Test fun blendWeightsShiftWithLeadTime() {
        val r = testRegion
        val values = mapOf(WeatherModel.germany to 0.0, WeatherModel.europe to 10.0)
        close(10 * 0.20 / 0.50, ModelBlend.blend(values, 6.0, r), 0.001)
        close(10 * 0.165 / 0.225, ModelBlend.blend(values, 200.0, r), 0.001)
        close(10 * 0.08 / (0.08 + 0.1375), ModelBlend.blend(values, 72.0, r), 0.001)
        assertNull(ModelBlend.blend(emptyMap(), 6.0))
        assertNull(ModelBlend.blend(mapOf(WeatherModel.bestMatch to 5.0), 6.0))
    }

    @Test fun blendFailureKeepsDefault() {
        // Every blend request fails: the region's models, then the worldwide retry.
        val p = OpenMeteoProvider(loader = loader { url -> (if (url.contains("models=")) 500 else 200) to sample })
        val f = sync { p.forecast(Coordinate.fallback) }
        assertEquals(-2.0, f.hourly[0].temperature)
    }

    @Test fun wmoCodesAndFormat() {
        assertEquals(WeatherCondition.clear, WeatherCondition.fromWmo(0))
        assertEquals(WeatherCondition.thunderstorm, WeatherCondition.fromWmo(95))
        assertEquals(WeatherCondition.unknown, WeatherCondition.fromWmo(null))
        assertEquals("0°", WeatherFormat.temperature(-0.3, TemperatureUnit.celsius))
        assertEquals("22°", WeatherFormat.temperature(21.6, TemperatureUnit.celsius))
        assertEquals("-3°", WeatherFormat.temperature(-2.5, TemperatureUnit.celsius), "halves round away from zero, like iOS")
        assertEquals("1.2 cm", WeatherFormat.snowAmount(1.2, PrecipitationUnit.metric))
        assertEquals("1.00 in snow", WeatherFormat.snowAmount(2.54, PrecipitationUnit.inches))
    }

    @Test fun regionalWeightsIsolateLocationsAndTaperWithLead() {
        val milton = Coordinate(43.513, -79.882)
        val london = Coordinate(51.5, -0.12)
        ModelBlend.setRegionalWeights(mapOf("germany" to 0.9, "europeAI" to 0.1), milton)
        ModelBlend.setRegionalWeights(mapOf("europe" to 0.9, "uk" to 0.1), london)

        val miltonDay0 = ModelBlend.weight(WeatherModel.germany, 12.0, BlendRegion.at(milton), milton)
        val londonDay0 = ModelBlend.weight(WeatherModel.germany, 12.0, BlendRegion.at(milton), london)
        assertNotEquals(miltonDay0, londonDay0)

        val baselineDay6 = ModelBlend.weight(WeatherModel.germany, 150.0, BlendRegion.at(milton))
        val miltonDay6 = ModelBlend.weight(WeatherModel.germany, 150.0, BlendRegion.at(milton), milton)
        assertTrue(miltonDay6 > baselineDay6)
    }

    @Test fun ensemblePrecipitationMeanReplacesSingleModelSpike() {
        val blend = """
        {
          "hourly": { "time": [1762952400],
                      "temperature_2m_gfs_seamless": [6.0], "temperature_2m_ecmwf_ifs025": [6.0],
                      "temperature_2m_icon_seamless": [6.0], "temperature_2m_ukmo_seamless": [6.0],
                      "precipitation_gfs_seamless": [0.4], "precipitation_ecmwf_ifs025": [0.4],
                      "precipitation_icon_seamless": [0.4], "precipitation_ukmo_seamless": [0.4],
                      "snowfall_gfs_seamless": [0.0], "snowfall_ecmwf_ifs025": [0.0],
                      "snowfall_icon_seamless": [0.0], "snowfall_ukmo_seamless": [0.0] }
        }
        """
        val p = OpenMeteoProvider(loader = loader { url -> 200 to (if (url.contains("models=")) blend else sample) })
        val f = sync { p.forecast(Coordinate.fallback) }
        close(0.4, f.hourly[0].precipitation, 0.001)
    }

    @Test fun regionSummaryMentionsRegionName() {
        val summary = BlendRegion.summary(Coordinate(51.5, -0.12))
        assertTrue(summary.contains("Europe"))
        assertFalse(summary.contains("Milton"))
    }

    @Test fun mixedTransitionPreservesBothRainAndSnow() {
        val precip = mapOf(WeatherModel.canadaHighRes to 1.0, WeatherModel.europeHighRes to 1.0)
        val snow = mapOf(WeatherModel.canadaHighRes to 1.0, WeatherModel.europeHighRes to 0.0)
        val share = ModelBlend.precipitationSnowShare(1.0, precip, snow)
        assertEquals(PrecipitationKind.mixed, ModelBlend.precipitationType(1.0, precip, snow))
        val hour = HourlyForecast(time = 0.0, temperature = 1.0, precipitation = 1.4, condition = WeatherCondition.rain)
        hour.setPrecipitationType(PrecipitationKind.mixed, share)
        close(0.7, hour.rain, 0.01)
        close(1.0, hour.snowfall, 0.01)
        assertTrue(hour.isMixedPrecipitation)
    }

    @Test fun staleMixedSummaryClearedWhenHoursBecomeAllRain() {
        val midnight = torontoMidnight(2026, 11, 26)
        val hours = (0 until 24).map { h ->
            HourlyForecast(time = midnight + h * 3600.0, temperature = 2.0,
                precipitation = if (h >= 19) 3.0 else 0.0,
                condition = if (h >= 19) WeatherCondition.rain else WeatherCondition.overcast,
                rain = if (h >= 19) 3.0 else 0.0, snowfall = 0.0)
        }
        val day = DailyForecast(date = midnight, high = 5.0, low = 1.0, precipitationProbability = 90.0,
            condition = WeatherCondition.rain, rainSum = 15.0, snowfallSum = 0.0, summary = "Rain then snow")
        val f = Forecast(Coordinate(43.5, -79.9), "America/Toronto",
            CurrentConditions(midnight, 2.0, 2.0, FeelsLikeKind.apparent, condition = WeatherCondition.overcast, isDay = false),
            hours, listOf(day), "test", midnight).withDailyHeadlines()
        assertEquals(WeatherCondition.rain, f.daily[0].condition)
        assertNull(f.daily[0].summary)
        assertFalse(f.daily[0].isMixedPrecipitation)
    }

    @Test fun implausibleHomeStationAnchorDoesNotSkewBlend() {
        val t0 = 1762952400
        val blend = """
        {
          "hourly": { "time": [$t0, ${t0 + 3600}],
                      "temperature_2m_gem_hrdps_continental": [2.0, 2.0],
                      "temperature_2m_icon_seamless": [10.0, 10.0],
                      "temperature_2m_ecmwf_aifs025_single": [2.0, 2.0] }
        }
        """.toByteArray()
        val badAnchor = ModelBlend.Anchor(14.0, t0.toDouble(), isHomeStation = true)
        val noAnchor = OpenMeteoProvider.parseBlend(blend, BlendRegion.home, null, t0.toDouble())
        val withBad = OpenMeteoProvider.parseBlend(blend, BlendRegion.home, badAnchor, t0.toDouble())
        close(noAnchor.hourly[t0.toLong()]!!.temperature, withBad.hourly[t0.toLong()]!!.temperature, 0.001)
    }

    @Test fun dailyExtremesRecoverTimingAttenuationAndSkipPartialDayModels() {
        val day0 = torontoMidnight(2026, 11, 25)
        val hours = (0 until 24).map { h ->
            val gTemp = if (h == 1) -2.0 else if (h == 12) 8.0 else 3.0
            val eTemp = if (h == 6) -2.0 else if (h == 16) 8.0 else 3.0
            HourlyForecast(time = day0 + h * 3600.0, temperature = (gTemp + eTemp) / 2.0, condition = WeatherCondition.overcast)
        }
        val temps = OpenMeteoProvider.ModelTemperatures().apply {
            region = testRegion
            now = day0
            for (h in 0 until 24) {
                val epoch = (day0 + h * 3600.0).toLong()
                val gTemp = if (h == 1) -2.0 else if (h == 12) 8.0 else 3.0
                val eTemp = if (h == 6) -2.0 else if (h == 16) 8.0 else 3.0
                val models = mutableMapOf(WeatherModel.germany to gTemp, WeatherModel.europe to eTemp)
                if (h < 8) models[WeatherModel.uk] = 1.0 // partial-day model must not distort daily extremes
                hourly[epoch] = OpenMeteoProvider.ModelTemperatures.Hour(
                    temperature = (gTemp + eTemp) / 2.0, feelsLike = null,
                    low = minOf(gTemp, eTemp), high = maxOf(gTemp, eTemp),
                    count = models.size, wet = 0, freezing = 0,
                    modelTemperatures = models,
                )
            }
        }
        val forecast = Forecast(
            Coordinate.fallback, "America/Toronto",
            CurrentConditions(day0, 3.0, 3.0, FeelsLikeKind.apparent, condition = WeatherCondition.overcast, isDay = false),
            hours, listOf(DailyForecast(date = day0, high = 5.0, low = 0.0, condition = WeatherCondition.overcast)),
            "test", day0,
        ).applying(temps)

        close(8.4, forecast.daily[0].high, 0.001)
        close(-1.25, forecast.daily[0].low, 0.001)
    }

    @Test fun diurnalBiasInterpolatesCyclicUTCIsolatesSpotsAndTapersNearAnchor() {
        val spotA = Coordinate(12.34, 45.67)
        val spotB = Coordinate(12.34, 45.90)
        ModelBlend.setDiurnalBias(listOf(1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0), spotA)

        // Exact UTC midnight: 20000 * 86400 = 1728000000
        val midnight = 1728000000L
        val h0130 = midnight + 5400
        val h1330 = midnight + 13 * 3600 + 1800

        close(0.5, ModelBlend.diurnalBias(midnight.toDouble(), 24.0, spotA), 0.001)
        close(1.0, ModelBlend.diurnalBias(h0130.toDouble(), 24.0, spotA), 0.001)
        close(-1.0, ModelBlend.diurnalBias(h1330.toDouble(), 24.0, spotA), 0.001)
        close(0.6, ModelBlend.diurnalBias(h0130.toDouble(), 216.0, spotA), 0.001)
        close(0.0, ModelBlend.diurnalBias(h0130.toDouble(), 24.0, spotB), 0.001)

        val blend = """
        {
          "hourly": { "time": [$h0130, $h1330],
                      "temperature_2m_gem_hrdps_continental": [5.0, 5.0],
                      "temperature_2m_icon_seamless": [5.0, 5.0],
                      "temperature_2m_ecmwf_aifs025_single": [5.0, 5.0] }
        }
        """.toByteArray()
        val farLead = OpenMeteoProvider.parseBlend(blend, BlendRegion.home, null, (midnight - 86400).toDouble(), spotA)
        close(4.0, farLead.hourly[h0130]!!.temperature, 0.001)
        close(6.0, farLead.hourly[h1330]!!.temperature, 0.001)
        close(4.0, farLead.hourly[h0130]!!.modelTemperatures[WeatherModel.canadaHighRes]!!, 0.001)

        val liveAnchor = ModelBlend.Anchor(5.0, h0130.toDouble())
        val anchored = OpenMeteoProvider.parseBlend(blend, BlendRegion.home, liveAnchor, h0130.toDouble(), spotA)
        close(5.0, anchored.hourly[h0130]!!.temperature, 0.001)
    }

    @Test fun likelyPrecipitationPromotesOvercastHourCondition() {
        val t0 = 1762952400.0
        val rainHour = HourlyForecast(time = t0, temperature = 4.0, precipitationProbability = 70.0,
            precipitation = 0.0, condition = WeatherCondition.overcast)
        rainHour.promoteLikelyPrecipitation()
        assertEquals(WeatherCondition.rain, rainHour.condition)

        val rain50 = HourlyForecast(time = t0, temperature = 4.0, precipitationProbability = 51.0,
            precipitation = 0.0, condition = WeatherCondition.overcast)
        rain50.promoteLikelyPrecipitation()
        assertEquals(WeatherCondition.rain, rain50.condition)

        val snowHour = HourlyForecast(time = t0, temperature = -2.0, precipitationProbability = 70.0,
            precipitation = 0.0, condition = WeatherCondition.overcast)
        snowHour.promoteLikelyPrecipitation()
        assertEquals(WeatherCondition.snow, snowHour.condition)

        val dryCloud = HourlyForecast(time = t0, temperature = 4.0, precipitationProbability = 25.0,
            precipitation = 0.0, condition = WeatherCondition.overcast)
        dryCloud.promoteLikelyPrecipitation()
        assertEquals(WeatherCondition.overcast, dryCloud.condition)
    }

    @Test fun relayOfficialProviderParsesNationalEuropeanStation() {
        val json = """
        {"station": {"name": "Wien-Innere Stadt", "observed": 1762952400, "temperature": 0.3, "humidity": 89.0, "wind_kmh": 10.8, "gust_kmh": 22.0, "wind_dir": 75.0, "distance_km": 1.32, "provider": "GeoSphere"}}
        """.toByteArray()
        val obs = RelayOfficialProvider.parse(json)!!
        assertEquals("Wien-Innere Stadt", obs.stationName)
        assertEquals("GeoSphere", obs.dataProvider)
        close(0.3, obs.temperature, 0.001)
    }

    private val testRegion get() = Regions.testRegion

    object Regions {
        /** A made-up region with the first (Pearson and Hamilton) weights for ICON and ECMWF. */
        val testRegion = BlendRegion("test", "Test", emptyList(), true, listOf(WeatherModel.germany, WeatherModel.europe),
            listOf(0.30 to 0.20, 0.22 to 0.04, 0.18 to 0.075, 0.095 to 0.085, 0.07 to 0.075, 0.06 to 0.165)
                .map { (g, e) -> mapOf(WeatherModel.germany to g, WeatherModel.europe to e) })
    }
}
