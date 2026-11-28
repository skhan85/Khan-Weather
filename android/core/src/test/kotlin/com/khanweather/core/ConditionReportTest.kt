package com.khanweather.core

import kotlin.test.*

/** "What's it doing now?" reports (28 Nov 2026), same cases as ConditionReportTests.swift. */
class ConditionReportTest {
    private val milton = Coordinate(43.513, -79.882)
    private val now = nowEpoch()

    private fun forecast(c: WeatherCondition = WeatherCondition.overcast) = Forecast(milton, "America/Toronto",
        CurrentConditions(now, 5.0, 3.0, FeelsLikeKind.apparent, humidity = 92.0, condition = c, isDay = false),
        emptyList(), emptyList(), "t", now).apply {
        val start = kotlin.math.floor(now / 900) * 900
        minutely = (0 until 8).map { PrecipitationSlot(start + it * 900, 0.0) }
        observation = Observation("3 Netatmo stations", now, 5.0, distanceKm = 2.0)
    }

    private fun report(kind: ReportKind, agoMin: Double, at: Coordinate = milton, mine: Boolean = true) =
        ConditionReport(kind = kind, time = now - agoMin * 60, latitude = at.latitude, longitude = at.longitude, mine = mine)

    @Test fun ownReportSetsCardAndNextTwoHours() {
        val shown = forecast().applyingReports(listOf(report(ReportKind.drizzle, 5.0)), now)
        assertEquals(WeatherCondition.drizzle, shown.current.condition)
        assertEquals("Drizzle", shown.observation?.conditionText)
        assertEquals("your report, 5 min ago", shown.skySource)
        assertEquals(Nowcast.Kind.rain, shown.nowcast(now)?.kind)
        assertEquals(5.0, shown.current.temperature)
    }

    @Test fun dryReportClearsRain() {
        val f = forecast(WeatherCondition.rain)
        f.minutely = f.minutely.toMutableList().also { it[0] = PrecipitationSlot(it[0].time, 0.5, 0.5) }
        val shown = f.applyingReports(listOf(report(ReportKind.cloudy, 0.0)), now)
        assertEquals(WeatherCondition.overcast, shown.current.condition)
        assertEquals("Cloudy", shown.observation?.conditionText)
        assertFalse(shown.minutely[0].isWet)
        assertTrue(f.minutely[0].isWet, "the original is untouched")
    }

    @Test fun reportsExpireAndStayLocal() {
        assertEquals(WeatherCondition.overcast, forecast().applyingReports(listOf(report(ReportKind.rain, 50.0)), now).current.condition)
        val oakville = Coordinate(43.45, -79.68)
        assertEquals(WeatherCondition.overcast, forecast().applyingReports(listOf(report(ReportKind.rain, 0.0, oakville)), now).current.condition)
        val shown = forecast().applyingReports(listOf(report(ReportKind.snow, 20.0, Coordinate(43.54, -79.88), mine = false)), now)
        assertEquals(WeatherCondition.snow, shown.current.condition)
        assertTrue(shown.skySource!!.startsWith("someone's report"))
    }

    @Test fun newestReportWinsAndMergeDedupes() {
        val a = report(ReportKind.rain, 20.0)
        val b = report(ReportKind.partlyCloudy, 2.0, mine = false)
        assertEquals(WeatherCondition.partlyCloudy, forecast().applyingReports(listOf(a, b), now).current.condition)
        assertEquals(1, ConditionReport.merged(listOf(a), listOf(a.copy(mine = false))).size)
    }

    @Test fun everyKindHasMatchingWetness() {
        for (k in ReportKind.values()) assertEquals(k.isWet, k.slot.first + k.slot.second > 0, k.name)
    }
}
