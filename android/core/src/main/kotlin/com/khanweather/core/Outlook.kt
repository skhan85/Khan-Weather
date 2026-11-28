package com.khanweather.core

/** One plain sentence about what's coming, shown on the Now card. */
object Outlook {
    /** On a day with rain or snow ahead, returns the longest contiguous dry stretch (>= 2 hr). */
    fun dryWindow(forecast: Forecast, date: Epoch = nowEpoch(), hourText: (Epoch) -> String): String? {
        val upcoming = forecast.hoursStartingNow(date, 14)
        if (upcoming.size < 4 || upcoming.take(12).none { (it.precipitationProbability ?: 0.0) >= 40.0 }) return null
        var bestStart = -1; var bestLen = 0; var curStart = -1; var curLen = 0
        for ((i, h) in upcoming.withIndex()) {
            val dry = (h.precipitationProbability ?: 0.0) < 25.0 && !h.condition.isPrecipitation
            if (dry) {
                if (curStart == -1) curStart = i
                curLen += 1
                if (curLen > bestLen) { bestLen = curLen; bestStart = curStart }
            } else {
                curStart = -1; curLen = 0
            }
        }
        if (bestLen < 2 || bestStart < 0) return null
        val start = upcoming[bestStart].time
        val end = upcoming[bestStart + bestLen - 1].time + 3600.0
        return "Driest window: ${hourText(start)} – ${hourText(end)}."
    }

    const val trendHours = 18
    const val nearHours = 6

    private fun shown(celsius: Double): Int = UnitSettings.current.temperature.convert(celsius).rndInt()

    private fun isCloudOnly(c: WeatherCondition) =
        c == WeatherCondition.mainlyClear || c == WeatherCondition.partlyCloudy || c == WeatherCondition.mostlyCloudy || c == WeatherCondition.overcast

    fun turningPoint(now: Int, later: List<HourlyForecast>, rising: Boolean): HourlyForecast? {
        var best: HourlyForecast? = null
        var bestShown = now
        for (hour in later.take(trendHours)) {
            val t = shown(hour.temperature)
            if (if (rising) t > bestShown else t < bestShown) {
                best = hour
                bestShown = t
            } else if (if (rising) t <= bestShown - 2 else t >= bestShown + 2) {
                break
            }
        }
        return best
    }

    fun text(forecast: Forecast, date: Epoch = nowEpoch(), hourText: (Epoch) -> String): String? {
        forecast.nowcast(date)?.let { return it.text }
        val later = forecast.hoursStartingNow(date, maxOf(trendHours + 1, 24)).drop(1)
        val near = later.take(nearHours)
        if (near.size < 3) return null
        val last = near.last()
        val now = forecast.current
        near.firstOrNull { (it.precipitationProbability ?: 0.0) >= 50 }?.let { wet ->
            return "${wet.precipitationKind.noun.replaceFirstChar { it.uppercase() }.capitalizeWords()} likely around ${hourText(wet.time)}."
        }
        val nowShown = shown(now.temperature)
        // Evening and night: tonight's low matters more than tomorrow afternoon's high.
        overnightLow(forecast, date, nowShown, hourText)?.let { return it }
        val peak = turningPoint(nowShown, later, true)
        val trough = turningPoint(nowShown, later, false)
        val warmDelta = peak?.let { shown(it.temperature) - nowShown } ?: 0
        val coolDelta = trough?.let { nowShown - shown(it.temperature) } ?: 0
        val target = if (warmDelta >= coolDelta) peak else trough
        if (maxOf(warmDelta, coolDelta) >= 2 && target != null) {
            val warming = warmDelta >= coolDelta
            val calendar = forecast.cal
            val day = forecast.displayDay(date)
            val dayValue = if (warming) day?.high else day?.low
            val isToday = if (warming) calendar.isSameDay(target.time, date) else target.time <= tonightEnd(date, calendar)
            val label = if (dayValue?.let(::shown) == shown(target.temperature) && isToday)
                (if (warming) "a high of " else "a low of ") else ""
            return "${if (warming) "Warming" else "Cooling"} to $label${WeatherFormat.temperature(target.temperature)} by ${hourText(target.time)}."
        }
        if (last.condition != now.condition && !(isCloudOnly(last.condition) && isCloudOnly(now.condition))) {
            return "${last.condition.description} by ${hourText(last.time)}."
        }
        val counts = near.groupingBy { shown(it.temperature) }.eachCount()
        val typical = counts.entries.sortedWith(compareByDescending<Map.Entry<Int, Int>> { it.value }.thenBy { it.key })
            .firstOrNull()?.key ?: nowShown
        val typicalHour = near.firstOrNull { shown(it.temperature) == typical } ?: last
        return "Steady around ${WeatherFormat.temperature(typicalHour.temperature)} for the next few hours."
    }

    /**
     * From 4 pm until 4 am, while it's still getting colder: "Cooling to a low of 3° by 6 am.",
     * with the same low as the Now card's high/low chip, by the hour the hourly curve first reaches its coldest number.
     */
    const val eveningStartHour = 16
    const val nightEndHour = 4

    private fun overnightLow(forecast: Forecast, date: Epoch, nowShown: Int, hourText: (Epoch) -> String): String? {
        val calendar = forecast.cal
        val hour = calendar.hour(date)
        if (hour < eveningStartHour && hour >= nightEndHour) return null
        if (forecast.tonightLow(date) == null) return null
        val low = forecast.displayDay(date)?.low ?: return null
        val end = tonightEnd(date, calendar)
        val tonight = forecast.hoursStartingNow(date, 24).filter { it.time > date && it.time <= end }
        // The first hour that reaches the coldest number the curve shows: "by" that hour.
        // Quote the curve's own temperature at that hour (and only label it "a low of " when
        // it matches the Now card's low chip), so the sentence never disagrees with the strip.
        val coldestShown = tonight.minOfOrNull { shown(it.temperature) } ?: return null
        if (coldestShown >= nowShown) return null
        val coldest = tonight.first { shown(it.temperature) == coldestShown }
        val label = if (shown(low) == coldestShown) "a low of " else ""
        return "Cooling to $label${WeatherFormat.temperature(coldest.temperature)} by ${hourText(coldest.time)}."
    }

    private fun tonightEnd(date: Epoch, calendar: Cal): Epoch {
        val start = calendar.startOfDay(date)
        val hours = if (calendar.hour(date) < 6) 9 else 33
        return start + hours * 3600.0
    }
}

/** Swift's `String.capitalized`: every word's first letter upper case. */
fun String.capitalizeWords(): String = split(" ").joinToString(" ") { w -> w.lowercase().replaceFirstChar { it.uppercase() } }
