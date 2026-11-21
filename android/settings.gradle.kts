pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    // Versions only; each plugin is resolved where a module applies it.
    plugins {
        id("com.android.application") version "8.7.3"
        kotlin("jvm") version "2.0.21"
        kotlin("android") version "2.0.21"
        kotlin("plugin.serialization") version "2.0.21"
        kotlin("plugin.compose") version "2.0.21"
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "KhanWeather"
include(":core")
// The Android app needs the Android SDK; `-PcoreOnly` skips it so the shared logic and its
// tests run on any machine with a JDK.
if (!providers.gradleProperty("coreOnly").isPresent) include(":app")
