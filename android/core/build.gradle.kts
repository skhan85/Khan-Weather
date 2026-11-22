import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm")
    kotlin("plugin.serialization")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    testImplementation(kotlin("test"))
}

tasks.test { useJUnitPlatform() }

// The blend's weights by region live in one table shared with the iOS app
// (Packages/WeatherCore/blend-regions.json). It is copied into a Kotlin string at build time,
// so both apps always use the same numbers.
val blendTable = rootProject.file("../Packages/WeatherCore/blend-regions.json")
val generatedDir = layout.buildDirectory.dir("generated/blend")
val generateBlendTable by tasks.registering {
    inputs.file(blendTable)
    outputs.dir(generatedDir)
    doLast {
        val text = blendTable.readText().replace("\$", "\${'$'}")
        val out = generatedDir.get().file("com/khanweather/core/BlendRegionTable.kt").asFile
        out.parentFile.mkdirs()
        out.writeText("package com.khanweather.core\n\n" +
            "// Generated from Packages/WeatherCore/blend-regions.json. Don't edit.\n" +
            "internal const val BLEND_REGIONS_JSON = \"\"\"" + text + "\"\"\"\n")
    }
}
kotlin.sourceSets["main"].kotlin.srcDir(generateBlendTable)
