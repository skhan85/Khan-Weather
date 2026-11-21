package com.khanweather.core

/** One plain sentence about what's coming, shown on the Now card. */
object Outlook {
    const val trendHours = 18
    const val nearHours = 6

    private fun shown(celsius: Double): Int = UnitSettings.current.temperature.convert(celsius).rndInt()

    private fun isCloudOnly(c: WeatherCondition) =
        c == WeatherCondition.mainlyClear || c == WeatherCondition.partlyCloudy || c == WeatherCondition.overcast

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
        val later = forecast.hoursStartingNow(date, trendHours + 1).drop(1)
        val near = later.take(nearHours)
        if (near.size < 3) return null
        val last = near.last()
        val now = forecast.current
        near.firstOrNull { (it.precipitationProbability ?: 0.0) >= 50 }?.let { wet ->
            return "${wet.precipitationKind.noun.replaceFirstChar { it.uppercase() }.capitalizeWords()} likely around ${hourText(wet.time)}."
        }
        val nowShown = shown(now.temperature)
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

    private fun tonightEnd(date: Epoch, calendar: Cal): Epoch {
        val start = calendar.startOfDay(date)
        val hours = if (calendar.hour(date) < 6) 9 else 33
        return start + hours * 3600.0
    }
}

/** Swift's `String.capitalized`: every word's first letter upper case. */
fun String.capitalizeWords(): String = split(" ").joinToString(" ") { w -> w.lowercase().replaceFirstChar { it.uppercase() } }
