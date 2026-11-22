@file:Suppress("EnumEntryName")

package com.khanweather.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import java.util.UUID

/** A public weather alert (warning, watch, advisory or statement) that covers the user's spot. */
@Serializable
data class WeatherAlert(
    val id: String,
    /** "Wind warning", sentence case. */
    val title: String,
    val kind: Kind,
    val risk: Risk,
    /** Full text, paragraphs separated by blank lines. */
    val text: String,
    /** Forecast region it was issued for, e.g. "Halton Hills - Milton". */
    val area: String? = null,
    val issuedAt: Epoch? = null,
    val expiresAt: Epoch? = null,
    /** When the weather itself is expected to end, if given. */
    val eventEndsAt: Epoch? = null,
    val source: String = "Environment and Climate Change Canada",
) {
    /** Warnings first (declaration order is the rank). */
    @Serializable
    enum class Kind { warning, watch, advisory, statement, other }

    @Serializable
    enum class Risk { red, orange, yellow, unknown }

    val readableParagraphs: List<String> get() = AlertText.paragraphs(text)
    val summary: String get() = AlertText.summary(text)

    /** Notification text: the useful lines only, cut at a word near 240 characters. */
    val notificationBody: String
        get() {
            val s = summary
            if (s.length <= 240) return s
            val cut = s.take(240)
            val end = cut.lastIndexOf(' ').let { if (it >= 0) it else cut.length }
            return cut.substring(0, end) + "…"
        }

    /** Environment Canada's colour-coded name, e.g. "Yellow advisory - fog". */
    val headline: String
        get() {
            if (risk == Risk.unknown) return title
            val kindWord = when (kind) {
                Kind.warning -> "warning"
                Kind.watch -> "watch"
                Kind.advisory -> "advisory"
                Kind.statement, Kind.other -> return title
            }
            val lower = title.lowercase()
            if (!lower.endsWith(" $kindWord")) return title
            val hazard = lower.dropLast(kindWord.length + 1).trim()
            if (hazard.isEmpty()) return title
            return "${risk.name.replaceFirstChar { it.uppercase() }} $kindWord - $hazard"
        }
}

/** Makes official alert text short enough to read on a phone. */
object AlertText {
    private val boilerplate = listOf(
        "continue to monitor", "report severe weather", "@ec.gc.ca", "are issued when", "is issued when",
        "for more information", "weather.gc.ca", "canada.ca", "getprepared", "visit www.", "please refer to",
    )

    fun paragraphs(raw: String, units: UnitSettings = UnitSettings.current): List<String> =
        plainParagraphs(raw).map { withUnits(it, units) }

    fun plainParagraphs(raw: String): List<String> {
        val paras = raw.replace("\r\n", "\n").split("\n\n").map(::normalise).filter { it.isNotEmpty() }
        val kept = paras.mapNotNull { para ->
            val joined = splitSentences(para).filter { !isBoilerplate(it) }.joinToString(" ")
            joined.ifEmpty { null }
        }
        return kept.ifEmpty { paras }
    }

    fun summary(raw: String, units: UnitSettings = UnitSettings.current): String = paragraphs(raw, units).joinToString(" ")

    private val unitPattern = Regex(
        "([-−]?\\d+(?:\\.\\d+)?)(?:\\s*(?:to|-|–|and)\\s*([-−]?\\d+(?:\\.\\d+)?))?\\s*" +
            "(mm|cm|km/h|kph|km|inches|inch|in\\.|mph|miles|mile|°C|°F)(?![\\w/])(?!\\s*\\()",
        RegexOption.IGNORE_CASE,
    )

    /**
     * Official alerts give amounts in their own country's units ("50 to 75 mm", "gusts of 90 km/h",
     * "6 inches"). When those aren't the person's units, add theirs after the original, which stays
     * word for word: "50 to 75 mm (2 to 3 in)".
     */
    fun withUnits(text: String, units: UnitSettings): String = unitPattern.replace(text) { m ->
        val a = m.groupValues[1].replace("−", "-").toDoubleOrNull()
        val b = m.groupValues[2].takeIf { it.isNotEmpty() }?.replace("−", "-")?.toDoubleOrNull()
        val extra = a?.let { converted(it, b, m.groupValues[3].lowercase(), units) }
        if (extra == null) m.value else "${m.value} ($extra)"
    }

    /** "2 to 3 in" for (50, 75, "mm") in US units; null when the text already uses the person's units. */
    fun converted(a: Double, b: Double?, unit: String, units: UnitSettings): String? {
        fun show(f: (Double) -> Double, label: String, decimals: Boolean): String {
            fun one(v: Double): String {
                val x = f(v)
                if (decimals && x < 1) return String.format(java.util.Locale.US, "%.1f", maxOf(0.1, (x * 10).rnd() / 10))
                return "${x.rndInt()}"
            }
            return (b?.let { "${one(a)} to ${one(it)}" } ?: one(a)) + (if (label.startsWith("°")) "" else " ") + label
        }
        val inches = units.precipitation == PrecipitationUnit.inches
        val miles = units.distance == DistanceUnit.mi
        val f = units.temperature == TemperatureUnit.fahrenheit
        return when (unit) {
            "mm" -> if (inches) show({ it / 25.4 }, "in", true) else null
            "cm" -> if (inches) show({ it / 2.54 }, "in", true) else null
            "inches", "inch", "in." -> if (inches) null else show({ it * 25.4 }, "mm", false)
            "km/h", "kph" -> if (units.wind == WindUnit.kmh) null else show({ units.wind.convert(it) }, units.wind.label, false)
            "mph" -> if (units.wind == WindUnit.mph) null else show({ units.wind.convert(it * 1.609344) }, units.wind.label, false)
            "km" -> if (miles) show({ it / 1.609344 }, "miles", true) else null
            "miles", "mile" -> if (miles) null else show({ it * 1.609344 }, "km", true)
            "°c" -> if (f) show({ it * 9 / 5 + 32 }, "°F", false) else null
            "°f" -> if (f) null else show({ (it - 32) * 5 / 9 }, "°C", false)
            else -> null
        }
    }

    fun normalise(s: String): String = s.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

    fun splitSentences(para: String): List<String> {
        val out = mutableListOf<String>()
        val current = StringBuilder()
        for (i in para.indices) {
            val c = para[i]
            current.append(c)
            if (c in ".!?" && i + 1 < para.length && para[i + 1] == ' ') {
                out.add(current.toString().trim())
                current.clear()
            }
        }
        val rest = current.toString().trim()
        if (rest.isNotEmpty()) out.add(rest)
        return out
    }

    fun isBoilerplate(sentence: String): Boolean {
        val s = sentence.lowercase()
        if (s == "###" || s.all { it == '#' || it == ' ' }) return true
        if (boilerplate.any { s.contains(it) }) return true
        if (s.startsWith("#") && !s.contains(" ")) return true
        return false
    }
}

interface AlertProvider {
    suspend fun alerts(near: Coordinate): List<WeatherAlert>
}

private fun capitalizeFirst(s: String) = s.take(1).uppercase() + s.drop(1)

/** Environment Canada public alerts from the MSC GeoMet OGC API. */
class ECCCAlertProvider(private val loader: HttpLoader = defaultLoader) : AlertProvider {
    override suspend fun alerts(near: Coordinate): List<WeatherAlert> =
        parse(loader.fetch(url(near), timeoutSeconds = 20), near, nowEpoch())

    companion object {
        fun url(coordinate: Coordinate): String {
            val c = coordinate.rounded
            val d = 0.01
            return buildUrl("https://api.weather.gc.ca/collections/weather-alerts/items",
                "f" to "json", "lang" to "en",
                "bbox" to ECCC.bbox(c.longitude - d, c.latitude - d, c.longitude + d, c.latitude + d, digits = 4),
                "limit" to "100")
        }

        fun parse(data: ByteArray, point: Coordinate, now: Epoch): List<WeatherAlert> {
            val features = parseJson(data)["features"].arr ?: throw ForecastException("missing features")
            val byID = linkedMapOf<String, WeatherAlert>()
            for (feature in features) {
                val p = feature["properties"]
                if (p["status_en"].str?.lowercase() == "ended") continue
                val expires = p["expiration_datetime"].str?.let { parseIsoDate(it) }
                if (expires != null && expires <= now) continue
                if (!contains(feature["geometry"], point)) continue
                val fid = feature["id"].str
                val alertID = fid?.split("_")?.firstOrNull()
                    ?: listOfNotNull(p["alert_code"].str, p["publication_datetime"].str).joinToString("-")
                if (byID.containsKey(alertID)) continue
                val name = p["alert_name_en"].str ?: p["alert_short_name_en"].str ?: "Weather alert"
                byID[alertID] = WeatherAlert(
                    id = alertID,
                    title = capitalizeFirst(name),
                    kind = WeatherAlert.Kind.entries.firstOrNull { it.name == p["alert_type"].str?.lowercase() } ?: WeatherAlert.Kind.other,
                    risk = WeatherAlert.Risk.entries.firstOrNull { it.name == p["risk_colour_en"].str?.lowercase() } ?: WeatherAlert.Risk.unknown,
                    text = p["alert_text_en"].str ?: "",
                    area = p["feature_name_en"].str,
                    issuedAt = p["publication_datetime"].str?.let { parseIsoDate(it) },
                    expiresAt = expires,
                    eventEndsAt = p["event_end_datetime"].str?.let { parseIsoDate(it) },
                )
            }
            return byID.values.sortedWith(compareBy<WeatherAlert> { it.kind.ordinal }
                .thenByDescending { it.issuedAt ?: Double.NEGATIVE_INFINITY })
        }

        /** GeoJSON Polygon or MultiPolygon with [lon, lat] positions. */
        fun contains(geometry: JsonElement?, point: Coordinate): Boolean {
            val coords = geometry["coordinates"].arr ?: return false
            val polygons: List<JsonArray> = when (geometry["type"].str) {
                "Polygon" -> listOf(coords)
                "MultiPolygon" -> coords.mapNotNull { it as? JsonArray }
                else -> return false
            }
            return polygons.any { rings ->
                val list = rings.mapNotNull { r -> (r as? JsonArray)?.mapNotNull { pt -> pt.arr?.mapNotNull { it.numOnly } } }
                val outer = list.firstOrNull() ?: return@any false
                if (!ring(outer, point)) return@any false
                list.drop(1).none { ring(it, point) }
            }
        }

        /** Ray casting. */
        fun ring(ring: List<List<Double>>, p: Coordinate): Boolean {
            val pts = ring.filter { it.size >= 2 }
            if (pts.size < 3) return false
            var inside = false
            var j = pts.size - 1
            for (i in pts.indices) {
                val xi = pts[i][0]; val yi = pts[i][1]
                val xj = pts[j][0]; val yj = pts[j][1]
                if ((yi > p.latitude) != (yj > p.latitude) &&
                    p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi) inside = !inside
                j = i
            }
            return inside
        }
    }
}

class NWSAlertProvider(private val loader: HttpLoader = defaultLoader) : AlertProvider {
    override suspend fun alerts(near: Coordinate): List<WeatherAlert> {
        if (!Region.inUS(near)) return emptyList()
        val c = near.rounded
        return parse(loader.fetch("https://api.weather.gov/alerts/active?point=${dstr(c.latitude)},${dstr(c.longitude)}", "application/geo+json"), nowEpoch())
    }

    companion object {
        fun parse(data: ByteArray, now: Epoch): List<WeatherAlert> {
            val features = parseJson(data)["features"].arr ?: throw ForecastException("missing features")
            return features.mapNotNull { f ->
                val p = f["properties"]
                val status = p["status"].str
                if (!(status == null || status == "Actual") || p["messageType"].str == "Cancel") return@mapNotNull null
                val ends = p["ends"].str?.let { parseIsoDate(it) }
                val expires = p["expires"].str?.let { parseIsoDate(it) }
                val end = ends ?: expires
                if (end != null && end <= now) return@mapNotNull null
                val event = p["event"].str ?: "Weather alert"
                val lower = event.lowercase()
                val kind = when {
                    lower.contains("warning") -> WeatherAlert.Kind.warning
                    lower.contains("watch") -> WeatherAlert.Kind.watch
                    lower.contains("advisory") -> WeatherAlert.Kind.advisory
                    lower.contains("statement") -> WeatherAlert.Kind.statement
                    else -> WeatherAlert.Kind.other
                }
                val risk = when (p["severity"].str) {
                    "Extreme" -> WeatherAlert.Risk.red
                    "Severe" -> WeatherAlert.Risk.orange
                    "Moderate", "Minor" -> WeatherAlert.Risk.yellow
                    else -> WeatherAlert.Risk.unknown
                }
                var text = p["description"].str ?: p["headline"].str ?: ""
                p["instruction"].str?.takeIf { it.isNotEmpty() }?.let { text += "\n\n" + it }
                WeatherAlert(p["id"].str ?: UUID.randomUUID().toString(), event, kind, risk, text, p["areaDesc"].str,
                    p["effective"].str?.let { parseIsoDate(it) }, expires, ends, "US National Weather Service")
            }.sortedBy { it.kind.ordinal }
        }
    }
}

class BrightSkyAlertProvider(private val loader: HttpLoader = defaultLoader) : AlertProvider {
    override suspend fun alerts(near: Coordinate): List<WeatherAlert> {
        if (!Region.inGermany(near)) return emptyList()
        val c = near.rounded
        val list = parseJson(loader.fetch("https://api.brightsky.dev/alerts?lat=${dstr(c.latitude)}&lon=${dstr(c.longitude)}"))["alerts"].arr
            ?: throw ForecastException("missing alerts")
        val now = nowEpoch()
        return list.mapNotNull { a ->
            val expires = a["expires"].str?.let { parseIsoDate(it) }
            if (expires != null && expires <= now) return@mapNotNull null
            val event = a["event_en"].str ?: a["headline_en"].str ?: "Weather warning"
            val risk = when (a["severity"].str) {
                "extreme" -> WeatherAlert.Risk.red
                "severe" -> WeatherAlert.Risk.orange
                "moderate", "minor" -> WeatherAlert.Risk.yellow
                else -> WeatherAlert.Risk.unknown
            }
            var text = a["description_en"].str ?: ""
            a["instruction_en"].str?.takeIf { it.isNotEmpty() }?.let { text += "\n\n" + it }
            WeatherAlert(a["alert_id"].str ?: (a["id"].numOnly?.toLong() ?: 0).toString(), capitalizeFirst(event),
                WeatherAlert.Kind.warning, risk, text, issuedAt = a["effective"].str?.let { parseIsoDate(it) },
                expiresAt = expires, source = "Deutscher Wetterdienst")
        }
    }
}

class WorldAlertProvider(
    private val providers: List<AlertProvider> = listOf(ECCCAlertProvider(), NWSAlertProvider(), BrightSkyAlertProvider()),
) : AlertProvider {
    override suspend fun alerts(near: Coordinate): List<WeatherAlert> {
        val all = mutableListOf<WeatherAlert>()
        var failures = 0
        for (p in providers) {
            try {
                all += p.alerts(near)
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                failures += 1
            }
        }
        // Only report failure when every service failed, so the app keeps its last list.
        if (failures == providers.size) throw ForecastException("The weather service response was missing alerts.")
        return all.sortedBy { it.kind.ordinal }
    }
}
