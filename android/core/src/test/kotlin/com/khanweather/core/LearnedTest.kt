package com.khanweather.core

import kotlinx.serialization.json.Json
import kotlin.test.*

class LearnedTest {
    private val json = """
    {"cell":"435,-799","days":21,"status":"correcting",
     "temperature":{"enabled":true,"bias_3h":[0.2,1.0,1.2,0.8,0.1,0,-0.1,0],"mae_raw":1.42,"mae_learned":1.12,"checked_days":14},
     "rain":{"enabled":true,"pop_factor":0.8,"wet_hours":60,"timing":null}}
    """

    @Test fun provenCorrectionReplacesRelayDiurnalBias() {
        val spot = Coordinate(12.34, 56.78)
        ModelBlend.setDiurnalBias(List(8) { 3.0 }, spot)
        val learned = Json { ignoreUnknownKeys = true }.decodeFromString(LearnedCorrections.serializer(), json)
        ModelBlend.setLearned(learned, spot)
        val h0430 = 4.5 * 3600 + 86400 * 100
        assertEquals(1.0, ModelBlend.diurnalBias(h0430, 24.0, spot), 0.001)
        assertEquals(0.8, ModelBlend.learnedPopFactor(spot), 0.001)
        assertTrue(learned.summary.contains("1.4° → 1.1°"))
        ModelBlend.setLearned(learned.copy(temperature = learned.temperature!!.copy(enabled = false), rain = null), spot)
        assertEquals(3.0, ModelBlend.diurnalBias(h0430, 24.0, spot), 0.001)
        assertEquals(1.0, ModelBlend.learnedPopFactor(spot), 0.001)
    }

    @Test fun stillLearningSaysSo() {
        val fresh = LearnedCorrections(status = "learning", days = 3)
        assertEquals("Learning this place: 3 of 10 days so far. Nothing is corrected until it proves itself.", fresh.summary)
    }
}
