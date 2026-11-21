package com.khanweather.core

import kotlinx.coroutines.runBlocking
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

fun close(expected: Double, actual: Double?, accuracy: Double = 1e-9, message: String? = null) {
    assertNotNull(actual, message)
    assertEquals(expected, actual, accuracy, message)
}

fun <T> sync(block: suspend () -> T): T = runBlocking { block() }

fun loader(handler: (String) -> Pair<Int, String>) = HttpLoader { url, _, _ ->
    val (code, body) = handler(url)
    if (code !in 200..299) throw HttpStatusException(code)
    body.toByteArray()
}

val torontoCal = Cal("America/Toronto")

fun torontoMidnight(y: Int, m: Int, d: Int): Epoch =
    java.time.LocalDate.of(y, m, d).atStartOfDay(torontoCal.zone).toEpochSecond().toDouble()
