package com.khanweather.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.test.*

private const val MIDNIGHT = 1_795_150_800.0 // 2026-11-20 00:00 Toronto
private val hourFmt = DateTimeFormatter.ofPattern("h a", Locale.US).withZone(ZoneId.of("America/Toronto"))
private fun hourText(t: Epoch) = hourFmt.format(Instant.ofEpochSecond(t.toLong())).replace("AM", "am").replace("PM", "pm")
private fun local(h: Int, extra: Int = 0) = MIDNIGHT + (h + extra) * 3600.0

class AlertTextTest {
    val fog = """
Locally dense fog will dissipate later this morning.

Travel will likely be hazardous in some locations.

Be prepared for areas of near-zero visibility and allow extra time to reach your destination.

Please continue to monitor alerts and forecasts issued by Environment Canada. To report severe weather, send an email to ONstorm@ec.gc.ca or post reports on social media using #ONStorm.
""".trimIndent()

    @Test fun dropsStockLines() {
        assertEquals(listOf(
            "Locally dense fog will dissipate later this morning.",
            "Travel will likely be hazardous in some locations.",
            "Be prepared for areas of near-zero visibility and allow extra time to reach your destination.",
        ), AlertText.paragraphs(fog))
        assertFalse(AlertText.summary(fog).contains("ONstorm"))
        val a = WeatherAlert("1", "Fog advisory", WeatherAlert.Kind.advisory, WeatherAlert.Risk.yellow, fog)
        assertTrue(a.notificationBody.startsWith("Locally dense fog"))
        assertTrue(a.notificationBody.length <= 241)
    }

    @Test fun joinsWrappedLines() {
        val raw = "Strong winds, with gusts up to\n90 km/h, are expected.\n\nWind warnings are issued when there is a significant risk of damaging winds.\n\n###"
        assertEquals(listOf("Strong winds, with gusts up to 90 km/h, are expected."), AlertText.paragraphs(raw))
        val all = "Please continue to monitor alerts and forecasts issued by Environment Canada."
        assertEquals(listOf(all), AlertText.paragraphs(all))
    }

    @Test fun headline() {
        fun a(t: String, k: WeatherAlert.Kind, r: WeatherAlert.Risk) = WeatherAlert("1", t, k, r, "")
        assertEquals("Yellow advisory - fog", a("Fog advisory", WeatherAlert.Kind.advisory, WeatherAlert.Risk.yellow).headline)
        assertEquals("Orange warning - severe thunderstorm", a("Severe thunderstorm warning", WeatherAlert.Kind.warning, WeatherAlert.Risk.orange).headline)
        assertEquals("Special weather statement", a("Special weather statement", WeatherAlert.Kind.statement, WeatherAlert.Risk.yellow).headline)
        assertEquals("Wind warning", a("Wind warning", WeatherAlert.Kind.warning, WeatherAlert.Risk.unknown).headline)
    }
}

class OutlookTest {
    fun forecast(startHour: Int, temps: List<Double>, high: Double, low: Double, rainAt: Int? = null): Forecast {
        val now = local(startHour)
        val hourly = temps.mapIndexed { i, t ->
            HourlyForecast(local(startHour, i), t, precipitationProbability = if (i == rainAt) 80.0 else 0.0,
                precipitation = if (i == rainAt) 1.0 else 0.0, condition = if (i == rainAt) WeatherCondition.rain else WeatherCondition.clear)
        }
        val current = CurrentConditions(now, temps[0], temps[0], FeelsLikeKind.apparent, condition = WeatherCondition.clear, isDay = false)
        val days = listOf(DailyForecast(local(0), high, low, condition = WeatherCondition.clear),
            DailyForecast(local(24), 12.0, 3.0, condition = WeatherCondition.clear))
        return Forecast(Coordinate.fallback, "America/Toronto", current, hourly, days, "test", now)
    }

    val early = listOf(9.0, 8.8, 8.6, 8.7, 9.0, 9.8, 11.0, 12.4, 13.6, 14.8, 15.0, 15.0, 14.2, 13.0, 11.5, 10.5, 10.0, 9.6, 9.2, 9.0)

    @Test fun earlyMorningReachesHigh() =
        assertEquals("Warming to a high of 15° by 1 pm.", Outlook.text(forecast(4, early, 15.0, 7.0), local(4), ::hourText))

    @Test fun notCalledHighWhenDiffers() =
        assertEquals("Warming to 15° by 1 pm.", Outlook.text(forecast(4, early, 17.0, 7.0), local(4), ::hourText))

    @Test fun eveningCooling() {
        val temps = listOf(11.0, 10.0, 9.0, 8.0, 7.0, 6.4, 5.6, 5.0, 4.6, 4.3, 4.1, 3.9, 4.0, 4.5, 5.5, 7.0, 9.0, 10.0, 11.0)
        val f = forecast(18, temps, 15.0, 7.0)
        assertEquals(3.9, f.displayDay(local(18))?.low)
        assertEquals("Cooling to a low of 4° by 3 am.", Outlook.text(f, local(18), ::hourText))
    }

    @Test fun warmUpStops() {
        val temps = listOf(5.0, 6.0, 7.0, 8.0, 7.0, 6.0, 5.5, 5.0, 6.0, 8.0, 10.0, 12.0, 13.0)
        assertEquals("Warming to 8° by 7 am.", Outlook.text(forecast(4, temps, 13.0, 5.0), local(4), ::hourText))
    }

    @Test fun rainFirst() =
        assertEquals("Rain likely around 7 am.", Outlook.text(forecast(4, early, 15.0, 7.0, rainAt = 3), local(4), ::hourText))

    @Test fun steady() {
        val temps = listOf(9.0, 9.2, 9.4, 9.1, 8.9, 9.3, 9.0, 9.4, 9.2)
        assertEquals("Steady around 9° for the next few hours.", Outlook.text(forecast(13, temps, 9.4, 8.9), local(13), ::hourText))
    }

    @Test fun numberMatchesCurve() {
        val curve = forecast(4, early, 15.0, 7.0).hoursStartingNow(local(4), 24)
        assertEquals("15°", curve.firstOrNull { it.time == local(13) }?.let { WeatherFormat.temperature(it.temperature) })
    }

    @Test fun compareRowShowsApp() {
        val today = MIDNIGHT
        val tomorrow = today + 86_400
        val rows = listOf(
            ModelDay(WeatherModel.blend, today, 16.2, 4.1, WeatherCondition.clear, null, null),
            ModelDay(WeatherModel.canada, today, 16.0, 4.0, WeatherCondition.clear, null, null),
            ModelDay(WeatherModel.blend, tomorrow, 12.4, 3.0, WeatherCondition.clear, null, null),
            ModelDay(WeatherModel.blend, tomorrow + 86_400, 9.0, 1.0, WeatherCondition.clear, null, null),
        )
        val app = listOf(DailyForecast(today, 15.1, 7.2, condition = WeatherCondition.clear),
            DailyForecast(tomorrow, 11.8, 3.4, condition = WeatherCondition.clear))
        val out = ModelComparisonProvider.showingApp(rows, app, WeatherModel.blend, "America/Toronto")
        assertEquals(15.1, out[0].high); assertEquals(7.2, out[0].low)
        assertEquals(16.0, out[1].high)
        assertEquals(11.8, out[2].high); assertEquals(3.4, out[2].low)
        assertEquals(9.0, out[3].high)
    }

    private fun peakForecast(): Pair<Forecast, Epoch> {
        val temps = listOf(7.5, 7.3, 7.1, 7.0, 7.2, 7.6, 7.9, 8.0, 8.1, 9.0, 11.0, 13.0, 15.4, 15.6, 15.4, 14.6,
            13.0, 11.5, 10.0, 8.5, 7.0, 5.5, 4.5, 3.8, 3.6, 3.4, 3.6, 4.0)
        val hourly = temps.mapIndexed { i, t -> HourlyForecast(MIDNIGHT + i * 3600.0, t, condition = WeatherCondition.clear) }
        val now = MIDNIGHT + 6 * 3600 + 40 * 60
        val current = CurrentConditions(now, 8.0, 6.0, FeelsLikeKind.apparent, condition = WeatherCondition.clear, isDay = false)
        val days = listOf(DailyForecast(MIDNIGHT, 15.6, 7.0, condition = WeatherCondition.clear),
            DailyForecast(MIDNIGHT + 86_400, 12.0, 3.1, condition = WeatherCondition.clear))
        return Forecast(Coordinate.fallback, "America/Toronto", current, hourly, days, "test", now) to now
    }

    @Test fun curveKeepsDaysHigh() {
        val (f, now) = peakForecast()
        val curve = f.hoursStartingNow(now, 24)
        assertEquals(16, curve.filter { it.time < MIDNIGHT + 86_400 }.maxOf { it.temperature.rndInt() })
        assertEquals("Warming to a high of 16° by 1 pm.", Outlook.text(f, now, ::hourText))
        assertEquals(3.4, curve.minOf { it.temperature })
    }
}
