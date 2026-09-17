pluginManagement {
    repositories {
        // Android Gradle Plugin / androidx artifacts live on Google's own
        // Maven repo, not mavenCentral (#96 - AGP swap; see
        // docs/handoffs/96.md).
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

rootProject.name = "adapter-android"

include(":app")
