package com.khanweather.app

import com.khanweather.core.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

/**
 * "What's it doing now?" reports: this phone's own, kept for an hour in Prefs, and the relay's
 * (family phones nearby), as in ConditionReports.swift. POST /v1/report sends one, DELETE takes it
 * back, GET /v1/reports lists the last hour's within 15 km.
 */
object Reports {
    private const val KEY = "conditionReports"
    private const val HOST = "https://weather-relay.khanofmilton.ca"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Serializable
    private data class Wire(val id: String, val kind: String, val t: Double, val lat: Double, val lon: Double)

    @Serializable
    private data class Listing(val reports: List<Wire> = emptyList())

    fun mine(now: Epoch = nowEpoch()): List<ConditionReport> {
        val raw = runCatching { Prefs.prefs.getString(KEY, null) }.getOrNull() ?: return emptyList()
        val all = runCatching { json.decodeFromString(ListSerializer(ConditionReport.serializer()), raw) }.getOrNull() ?: return emptyList()
        return all.filter { now - it.time < 3600 }
    }

    private fun save(list: List<ConditionReport>) {
        Prefs.prefs.edit().putString(KEY, json.encodeToString(ListSerializer(ConditionReport.serializer()), list)).apply()
    }

    fun add(r: ConditionReport) = save(mine() + r)

    /** Undo: forgets this phone's reports near `c` and returns their ids for the relay. */
    fun removeMine(c: Coordinate): List<String> {
        val all = mine()
        val gone = all.filter { distanceKm(it.coordinate, c) <= ConditionReport.MAX_KM }
        save(all - gone.toSet())
        return gone.map { it.id }
    }

    private fun round3(v: Double) = Math.round(v * 1000) / 1000.0

    suspend fun send(r: ConditionReport): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val body = json.encodeToString(Wire.serializer(),
                Wire(r.id, r.kind.name, r.time, round3(r.latitude), round3(r.longitude)))
            val conn = (URL("$HOST/v1/report").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"; doOutput = true; connectTimeout = 6000; readTimeout = 6000
                setRequestProperty("Content-Type", "application/json")
            }
            try {
                conn.outputStream.use { it.write(body.toByteArray()) }
                conn.responseCode == 200
            } finally { conn.disconnect() }
        }.getOrDefault(false)
    }

    suspend fun withdraw(ids: List<String>) = withContext(Dispatchers.IO) {
        for (id in ids) runCatching {
            val conn = (URL("$HOST/v1/report").openConnection() as HttpURLConnection).apply {
                requestMethod = "DELETE"; doOutput = true; connectTimeout = 6000; readTimeout = 6000
                setRequestProperty("Content-Type", "application/json")
            }
            try {
                conn.outputStream.use { it.write("""{"id":"$id"}""".toByteArray()) }
                conn.responseCode
            } finally { conn.disconnect() }
        }
    }

    /** Everyone's reports near `c` from the relay (this phone's come back too). */
    suspend fun nearby(c: Coordinate): List<ConditionReport> = withContext(Dispatchers.IO) {
        runCatching {
            val u = String.format(Locale.US, "$HOST/v1/reports?lat=%.3f&lon=%.3f", c.latitude, c.longitude)
            val conn = (URL(u).openConnection() as HttpURLConnection).apply { connectTimeout = 4000; readTimeout = 4000 }
            try {
                if (conn.responseCode != 200) return@runCatching emptyList()
                json.decodeFromString(Listing.serializer(), conn.inputStream.bufferedReader().readText()).reports.mapNotNull { w ->
                    val kind = ReportKind.values().firstOrNull { it.name == w.kind } ?: return@mapNotNull null
                    ConditionReport(w.id, kind, w.t, w.lat, w.lon, mine = false)
                }
            } finally { conn.disconnect() }
        }.getOrDefault(emptyList())
    }

    /** This phone's and the relay's, merged. */
    suspend fun all(c: Coordinate): List<ConditionReport> = ConditionReport.merged(mine(), nearby(c))
}
