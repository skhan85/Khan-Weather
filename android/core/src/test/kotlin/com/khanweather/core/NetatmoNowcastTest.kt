package com.khanweather.core

import kotlin.test.*

class NetatmoRelayTest {
    val milton = Coordinate(43.513, -79.882)
    val now = 1794581000.0

    val sample = """
    {"generated":1794580900,"stations":[
      {"lat":43.5142,"lon":-79.8845,"distance_km":0.74,"city":"Milton","altitude":192,"temperature":1.8,"observed":1794580705,"humidity":95,"pressure":1007.4},
      {"lat":43.52,"lon":-79.84,"distance_km":3.5,"city":"Milton","temperature":2.4,"observed":1794580600,"humidity":79,"wind_strength":10,"wind_angle":223,"gust_strength":19},
      {"lat":43.505,"lon":-79.87,"distance_km":1.3,"city":"Milton","temperature":9.9,"observed":1794580650,"humidity":60},
      {"lat":43.58,"lon":-79.77,"distance_km":11,"city":"Mississauga","temperature":4,"observed":1794580700,"humidity":72},
      {"lat":43.511,"lon":-79.88,"city":"Milton","temperature":-5,"observed":1794570000}
    ]}
    """

    fun parse(json: String, near: Coordinate = milton) =
        NetatmoRelayProvider.parse(json.toByteArray(), near, now, 5.0, 3600.0)

    @Test fun medianOfNearestThree() {
        val o = assertNotNull(parse(sample))
        assertEquals(2.1, o.temperature)
        close(87.0, o.humidity, 0.01)
        assertEquals(10.0, o.windSpeed)
        assertEquals("2 Netatmo stations in Milton", o.stationName)
        assertEquals("NETATMO", o.dataProvider)
        close(0.27, o.distanceKm, 0.1)
    }

    @Test fun twoNearbyMadeUpToThree() {
        val json = """{"stations":[
          {"lat":43.513,"lon":-79.86,"city":"Milton","temperature":5.0,"observed":1794580700},
          {"lat":43.513,"lon":-79.85,"city":"Milton","temperature":6.0,"observed":1794580700},
          {"lat":43.513,"lon":-79.80,"city":"Milton","temperature":5.2,"observed":1794580700},
          {"lat":43.513,"lon":-79.70,"city":"Mississauga","temperature":9.0,"observed":1794580700}]}"""
        val o = assertNotNull(parse(json))
        assertEquals(5.2, o.temperature)
        assertEquals("3 Netatmo stations in Milton", o.stationName)
    }

    @Test fun onlyFarStations() {
        assertNull(parse("""{"stations":[{"lat":43.513,"lon":-79.80,"temperature":5.2,"observed":1794580700}]}"""))
        assertNull(parse(sample, Coordinate(45.0, -75.0)))
    }

    @Test fun smoothing() {
        val before = Observation("2 Netatmo stations", now, 5.4, dataProvider = "NETATMO")
        val after = Observation("2 Netatmo stations", now + 1200, 5.8, dataProvider = "NETATMO")
        close(5.6, after.smoothed(before, now + 1260).temperature)
        val jump = after.copy(temperature = 8.0)
        assertEquals(8.0, jump.smoothed(before, now + 1260).temperature)
        assertEquals(5.8, after.smoothed(before, now + 3600).temperature)
        assertEquals(5.8, after.smoothed(null).temperature)
    }

    @Test fun plainSourceWords() {
        val home = Observation("3 Netatmo stations in Milton", now, 2.0, distanceKm = 2.9, dataProvider = "NETATMO")
        assertEquals("3 home weather stations about 3 km away", WeatherFormat.readingSource(home))
        assertEquals("Toronto Pearson, about 25 km away", WeatherFormat.readingSource(Observation("Toronto Pearson", now, 2.0, distanceKm = 25.2)))
        assertEquals("Campbellville", WeatherFormat.plainStationName("CR-27 Campbellville"))
        assertEquals("Burlington Lift Bridge", WeatherFormat.plainStationName("Burlington Lift Bridge"))
    }

    @Test fun mergeKeepsOfficialSky() {
        val official = Observation("Toronto Pearson", now, 3.0, humidity = 70.0, windSpeed = 20.0, windDirection = 270.0,
            condition = WeatherCondition.rain, conditionText = "Light Rain", distanceKm = 25.0, dataProvider = "ON-MTO")
        val local = Observation("2 Netatmo stations in Milton", now, 2.0, humidity = 90.0, distanceKm = 0.5)
        val m = HyperlocalObservationProvider.merge(official, local)
        assertEquals(2.0, m.temperature)
        assertEquals(WeatherCondition.rain, m.condition)
        assertEquals("Toronto Pearson", m.skyStationName)
        assertEquals("ON-MTO", m.skyDataProvider)
        assertNull(m.windSpeed)
    }

    @Test fun officialLocalWinsWhenFarApart() {
        val official = Observation("CR-27 Campbellville", now, 3.0, distanceKm = 8.0)
        val warm = Observation("2 Netatmo stations in Milton", now, 6.5, distanceKm = 1.0)
        assertEquals("CR-27 Campbellville", HyperlocalObservationProvider.merge(official, warm).stationName)
        val near = Observation("2 Netatmo stations in Milton", now, 4.0, distanceKm = 1.0)
        assertEquals(4.0, HyperlocalObservationProvider.merge(official, near).temperature)
    }

    @Test fun sunnyStationsDropped() {
        val official = Observation("CR-27 Campbellville", now, 6.0, distanceKm = 8.0)
        val local = Observation("3 Netatmo stations in Milton", now, 9.4, distanceKm = 0.24, dataProvider = "NETATMO",
            stationTemperatures = listOf(7.1, 16.4, 9.4, 9.9, 9.5))
        val m = HyperlocalObservationProvider.merge(official, local)
        assertEquals("NETATMO", m.dataProvider)
        assertEquals(7.1, m.temperature)
        assertEquals("Netatmo station in Milton", m.stationName)
        assertEquals("CR-27 Campbellville",
            HyperlocalObservationProvider.merge(official, local.copy(stationTemperatures = listOf(16.4, 9.9))).stationName)
    }

    fun rainyForecast() = Forecast(milton, "America/Toronto",
        CurrentConditions(now, 5.0, 2.0, FeelsLikeKind.apparent, condition = WeatherCondition.rain, isDay = true),
        emptyList(), emptyList(), "t", now)

    @Test fun dryGaugesOverruleDistantRain() {
        val json = """{"stations":[
          {"lat":43.5142,"lon":-79.8845,"city":"Milton","temperature":7.1,"observed":1794580705,"rain_60min":0},
          {"lat":43.52,"lon":-79.84,"city":"Milton","temperature":6.9,"observed":1794580600}]}"""
        val local = assertNotNull(parse(json))
        assertEquals(1, local.rainGauges)
        assertTrue(local.gaugesSayDry)
        val pearson = Observation("Toronto Pearson", now, 6.0, condition = WeatherCondition.rain, conditionText = "Light Rain", distanceKm = 25.0)
        val shown = rainyForecast().applying(HyperlocalObservationProvider.merge(pearson, local))
        assertEquals(WeatherCondition.overcast, shown.current.condition)
        assertNull(shown.observation?.conditionText)
        assertEquals(WeatherCondition.overcast, shown.applyingRadar(RadarNow(0.3, 0.0, now)).current.condition)
        assertEquals(WeatherCondition.rain, shown.applyingRadar(RadarNow(4.0, 0.0, now)).current.condition)
    }

    @Test fun wetGaugeKeepsRain() {
        val local = assertNotNull(parse("""{"stations":[{"lat":43.5142,"lon":-79.8845,"temperature":7,"observed":1794580705,"rain_60min":0.4}]}"""))
        assertFalse(local.gaugesSayDry)
    }

    @Test fun dryRadarOverrulesDistantRain() {
        val local = Observation("2 Netatmo stations in Milton", now, 7.0, distanceKm = 2.9)
        val pearson = Observation("Toronto Pearson", now, 6.0, condition = WeatherCondition.rain, conditionText = "Light Rain", distanceKm = 25.0)
        val merged = HyperlocalObservationProvider.merge(pearson, local)
        assertFalse(merged.skyIsLocal)
        val f = rainyForecast().applying(merged)
        assertEquals(WeatherCondition.rain, f.current.condition)
        val dry = f.applyingRadar(RadarNow(0.0, 0.0, now))
        assertEquals(WeatherCondition.overcast, dry.current.condition)
        assertNull(dry.observation?.conditionText)
    }
}

class NowcastTest {
    val start = 1_762_956_000.0

    fun forecast(slots: List<Pair<Double, Double>>): Forecast {
        val current = CurrentConditions(start, 1.0, 1.0, FeelsLikeKind.apparent, condition = WeatherCondition.overcast, isDay = true)
        val minutely = slots.mapIndexed { i, s ->
            PrecipitationSlot(start + i * 900.0, s.first, if (s.second > 0) 0.0 else s.first, s.second)
        }
        return Forecast(Coordinate(43.5, -79.9), "America/Toronto", current, emptyList(), emptyList(), "test", start, minutely = minutely)
    }

    @Test fun rainStarting() {
        val n = forecast(listOf(0.0 to 0.0, 0.0 to 0.0, 0.4 to 0.0, 0.8 to 0.0, 0.0 to 0.0)).nowcast(start + 300)
        assertEquals(Nowcast(Nowcast.Kind.rain, Nowcast.Change.Starting(25)), n)
        assertEquals("Rain starting in about 25 min", n?.text)
    }

    @Test fun snowStopping() {
        val n = forecast(List(5) { 0.3 to 0.2 } + listOf(0.0 to 0.0)).nowcast(start)
        assertEquals(Nowcast(Nowcast.Kind.snow, Nowcast.Change.Stopping(75)), n)
        assertEquals("Snow stopping in about 1 hr 15 min", n?.text)
    }

    @Test fun continuing() {
        assertEquals(Nowcast.Change.Continuing, forecast(List(12) { 0.5 to 0.0 }).nowcast(start)?.change)
    }

    @Test fun dryOrStaleIsNull() {
        assertNull(forecast(List(12) { 0.0 to 0.0 }).nowcast(start))
        assertNull(forecast(listOf(0.05 to 0.0)).nowcast(start))
        assertNull(forecast(listOf(0.0 to 0.0, 1.0 to 0.0)).nowcast(start - 3600))
        assertNull(forecast(List(9) { 0.0 to 0.0 } + listOf(1.0 to 0.0)).nowcast(start))
    }

    @Test fun dailyTotalsFormat() {
        assertEquals("3 mm", WeatherFormat.precipitationTotals(3.4, 0.0))
        assertEquals("2 cm, 1 mm", WeatherFormat.precipitationTotals(0.6, 2.2))
        assertNull(WeatherFormat.precipitationTotals(0.2, null))
    }

    @Test fun dryGaugesOverrideCurrentWetSlot() {
        val f = forecast(listOf(0.4 to 0.0, 0.0 to 0.0))
        f.current.temperature = 5.0
        f.observation = Observation("Milton PWS", start, 5.0, distanceKm = 1.0, rainGauges = 2, rainLastHourMm = 0.0)
        assertNull(f.nowcast(start))
    }

    @Test fun dryGaugesDoNotCancelSnow() {
        val f = forecast(listOf(0.3 to 0.2, 0.3 to 0.2, 0.0 to 0.0))
        f.current.temperature = -2.0
        f.observation = Observation("Milton PWS", start, -2.0, distanceKm = 1.0, rainGauges = 2, rainLastHourMm = 0.0)
        assertEquals(Nowcast.Kind.snow, f.nowcast(start)?.kind)
        f.current.temperature = 2.0
        assertEquals(Nowcast.Kind.snow, f.nowcast(start)?.kind)
    }

    @Test fun radarInjectsCurrentPrecipitation() {
        val f = forecast(listOf(0.0 to 0.0, 0.3 to 0.0, 0.0 to 0.0))
        f.radar = RadarNow(2.0, 0.0, start)
        val n = f.nowcast(start)
        assertEquals(Nowcast.Change.Stopping(30), n?.change)
        assertEquals(Nowcast.Kind.rain, n?.kind)

        val mixed = forecast(listOf(0.0 to 0.0, 0.0 to 0.0))
        mixed.radar = RadarNow(1.2, 0.8, start)
        assertEquals(Nowcast.Kind.mixed, mixed.nowcast(start)?.kind)
    }
}
