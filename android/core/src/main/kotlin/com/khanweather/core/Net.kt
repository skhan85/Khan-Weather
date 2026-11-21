package com.khanweather.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** NWS asks every client to identify itself. */
const val USER_AGENT = "KhanWeather-Android/0.1 (github.com/skhan85/Khan-Weather)"

/** Fetches a URL; throws on a non-2xx answer. Swappable in tests. */
fun interface HttpLoader {
    suspend fun get(url: String, accept: String?, timeoutMs: Int): ByteArray
}

class HttpStatusException(val code: Int) : Exception("The weather service returned HTTP $code.")

val defaultLoader = HttpLoader { url, accept, timeoutMs ->
    withContext(Dispatchers.IO) {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            c.setRequestProperty("User-Agent", USER_AGENT)
            if (accept != null) c.setRequestProperty("Accept", accept)
            val code = c.responseCode
            if (code !in 200..299) throw HttpStatusException(code)
            c.inputStream.use { it.readBytes() }
        } finally {
            c.disconnect()
        }
    }
}

suspend fun HttpLoader.fetch(url: String, accept: String? = null, timeoutSeconds: Int = 15): ByteArray =
    get(url, accept, timeoutSeconds * 1000)

/** Builds "base?a=1&b=2", leaving commas, colons and slashes readable. */
fun buildUrl(base: String, vararg items: Pair<String, String>): String {
    fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
        .replace("%2C", ",").replace("%3A", ":").replace("%2F", "/").replace("+", "%20")
    return base + "?" + items.joinToString("&") { "${enc(it.first)}=${enc(it.second)}" }
}

/** Swift's `String(double)`: "43.5" or "-79.8833". */
fun dstr(d: Double): String = d.toString()

fun fmt(pattern: String, vararg args: Any?): String = String.format(java.util.Locale.US, pattern, *args)

/** Runs `block`, giving up with null after `seconds`. */
suspend fun <T> deadline(seconds: Double, block: suspend () -> T?): T? =
    withTimeoutOrNull((seconds * 1000).toLong()) { try { block() } catch (e: Exception) { if (e is kotlinx.coroutines.CancellationException) throw e; null } }

val lenientJson = Json { ignoreUnknownKeys = true; isLenient = true; explicitNulls = false; coerceInputValues = true }

fun parseJson(data: ByteArray): JsonElement = lenientJson.parseToJsonElement(data.decodeToString())

// Small readers over JsonElement, like Swift's `as? [String: Any]` casts.
val JsonElement?.obj: JsonObject? get() = this as? JsonObject
val JsonElement?.arr: JsonArray? get() = this as? JsonArray
operator fun JsonElement?.get(key: String): JsonElement? = (this as? JsonObject)?.get(key)

/** A number, or a numeric string. */
val JsonElement?.num: Double?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        if (p.isString) return p.content.trim().toDoubleOrNull()
        return p.doubleOrNull
    }

/** A JSON number only (not a string), like Swift's `as? NSNumber`. */
val JsonElement?.numOnly: Double?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull || p.isString) return null
        if (p.booleanOrNull != null) return null
        return p.doubleOrNull
    }

val JsonElement?.str: String?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull || !p.isString) return null
        return p.content
    }

/** An array of numbers-or-null, as Open-Meteo returns them. */
fun JsonElement?.doubles(): List<Double?> = (this as? JsonArray)?.map { it.numOnly } ?: emptyList()

fun <T> List<T?>?.at(i: Int): T? = if (this == null || i < 0 || i >= size) null else this[i]
