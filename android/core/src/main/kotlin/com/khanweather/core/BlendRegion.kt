package com.khanweather.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive

/**
 * Where the blend's weights come from: one set per part of the world. Port of the iOS
 * BlendRegion.swift. The numbers come from Packages/WeatherCore/blend-regions.json, the same
 * table the iOS app is generated from (copied in at build time, see core/build.gradle.kts).
 */
data class BlendRegion(
    val id: String,
    val name: String,
    val boxes: List<Box>,
    /** Whether the blend beat best match here (else the app keeps best match's temperatures). */
    val useBlend: Boolean,
    /** The models asked for here; all vote on rain or snow, those with a weight make the temperatures. */
    val models: List<WeatherModel>,
    /** Weights by forecast day, centred at lead hours 12, 36, 60, 84, 108 and 132. */
    val byDay: List<Map<WeatherModel, Double>>,
    /** Weights for lead hours 0-2, 3-5 and 6-11 (centred at SHORT_RANGE_CENTRES), from each model's
     *  newest run (tools/score_short_range.py). Empty where they didn't beat byDay[0]. */
    val shortRange: List<Map<WeatherModel, Double>> = emptyList(),
) {
    /** latitude latMin..latMax, longitude lonMin..lonMax (degrees east). */
    data class Box(val latMin: Double, val latMax: Double, val lonMin: Double, val lonMax: Double) {
        fun contains(c: Coordinate): Boolean = c.latitude in latMin..latMax && c.longitude in lonMin..lonMax
    }

    companion object {
        val SHORT_RANGE_CENTRES = listOf(1.0, 4.0, 8.5)

        private fun parse(o: JsonObject): BlendRegion {
            fun model(name: String): WeatherModel =
                WeatherModel.entries.firstOrNull { it.name == name } ?: error("Unknown model $name in blend-regions.json")
            return BlendRegion(
                id = o["id"].str!!,
                name = o["name"].str ?: "",
                boxes = o["boxes"].arr.orEmpty().map { b ->
                    val v = b.arr!!.map { it.numOnly!! }
                    Box(v[0], v[1], v[2], v[3])
                },
                useBlend = o["useBlend"]!!.jsonPrimitive.boolean,
                models = o["models"].arr!!.map { model(it.str!!) },
                byDay = o["byDay"].arr!!.map { day -> day.obj!!.entries.associate { (k, v) -> model(k) to v.numOnly!! } },
                shortRange = o["shortRange"].arr.orEmpty().map { b -> b.obj!!.entries.associate { (k, v) -> model(k) to v.numOnly!! } },
            )
        }

        private val table: Pair<List<BlendRegion>, BlendRegion> by lazy {
            val root = parseJson(BLEND_REGIONS_JSON.toByteArray())
            root["regions"].arr!!.map { parse(it.obj!!) } to parse(root["global"].obj!!)
        }

        /** Regions in lookup order: the first whose box holds the spot wins. */
        val regions: List<BlendRegion> get() = table.first

        /** Everywhere else. */
        val fallback: BlendRegion get() = table.second

        /** The region for a spot: the first whose box holds it, else the worldwide weights. */
        fun at(c: Coordinate): BlendRegion = regions.firstOrNull { r -> r.boxes.any { it.contains(c) } } ?: fallback

        /** The region of the app's default spot (Toronto); used when a caller names none. */
        val home: BlendRegion get() = at(Coordinate.fallback)

        /** Plain-English explanation of how temperatures are blended at `coordinate`. */
        fun summary(c: Coordinate): String {
            val region = at(c)
            val regionLabel = region.name.ifBlank { "your region" }
            fun topNames(weights: Map<WeatherModel, Double>?): String? {
                if (weights.isNullOrEmpty()) return null
                val picked = weights.entries.filter { it.value > 0.0 }
                    .sortedByDescending { it.value }
                    .take(3)
                    .map { it.key.displayName }
                return when (picked.size) {
                    0 -> null
                    1 -> picked[0]
                    2 -> "${picked[0]} and ${picked[1]}"
                    else -> "${picked[0]}, ${picked[1]} and ${picked[2]}"
                }
            }
            val today = topNames(region.byDay.firstOrNull())
            val laterDay = if (region.byDay.size > 2) region.byDay[2] else region.byDay.lastOrNull()
            val later = topNames(laterDay)
            val parts = mutableListOf(
                "Khan Weather's temperatures are a blend tailored for $regionLabel, tuned by regional accuracy and updated with recent performance nearby."
            )
            if (today != null && later != null && today != later) {
                parts += "Today $today lead; further out $later carry the most weight."
            } else if (today != null) {
                parts += "$today carry the most weight."
            }
            parts += "The first hours are also eased toward nearby station readings."
            return parts.joinToString(" ")
        }
    }
}
