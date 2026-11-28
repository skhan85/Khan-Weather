package com.khanweather.core

import kotlinx.coroutines.runBlocking
import kotlin.test.*

class NeighbourStationTest {
    val nyc = Coordinate(40.75, -73.95)
    val now = 1795000000.0

    class Fixed(val result: Observation?) : ObservationProvider {
        override suspend fun observation(near: Coordinate) = result
    }

    @Test fun worldAsksModelAtDistantStationOnly() = runBlocking {
        val far = Observation("Airport", now, 4.0, distanceKm = 25.0, stationCoordinate = Coordinate(40.9, -73.9))
        fun world(o: Observation) = WorldObservationProvider(Fixed(null), Fixed(null), Fixed(null), Fixed(null), Fixed(o),
            modelAtStation = { _, _ -> 2.5 })
        assertEquals(2.5, world(far).observation(nyc)?.modelAtStation)
        assertNull(world(far.copy(distanceKm = 6.0)).observation(nyc)?.modelAtStation)
    }

    @Test fun distantStationShiftsNowByPartOfModelError() {
        val o = Observation("Airport", now, 6.0, distanceKm = 25.0, dataProvider = "METAR", modelAtStation = 4.0)
        val share = Observation.neighbourShare(25.0)
        assertEquals(2 * share, o.neighbourShift!!, 1e-9)
        val hours = (0 until 14).map { HourlyForecast(now + it * 3600, 3.0, condition = WeatherCondition.overcast) }
        val f = Forecast(nyc, "America/New_York",
            CurrentConditions(now, 3.0, 1.0, FeelsLikeKind.apparent, condition = WeatherCondition.overcast, isDay = true),
            hours, emptyList(), "t", now).applying(o)
        assertEquals(3 + 2 * share, f.current.temperature, 1e-9)
        assertEquals(3 + 2 * share, f.hourly[0].temperature, 1e-9)
        assertEquals(3.0, f.hourly[13].temperature, 1e-9)
        assertNull(o.copy(distanceKm = 60.0).neighbourShift)
        assertNull(o.copy(modelAtStation = -5.0).neighbourShift)
        assertNull(o.copy(dataProvider = "NETATMO").neighbourShift)
    }
}
