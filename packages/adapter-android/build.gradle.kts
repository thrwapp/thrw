plugins {
    // #96: AGP swap - real android.app.Service / NotificationListenerService /
    // android.bluetooth / android.telephony implementations can't compile
    // against the plain Kotlin/JVM scaffold this module used to be (see
    // docs/handoffs/66.md's "Uncertain / judgment calls" for the original
    // deferral, docs/handoffs/96.md for this swap). Versions declared here
    // (`apply false`), applied per-module below.
    // 8.11, not the 8.7.3 this landed on: #237. The maximum API level
    // AGP 8.9 supports is 35, and `compileSdk 36` is non-negotiable -
    // Play rejects an API 35 upload outright, on the internal testing
    // track as much as on production. 8.11 is the *lowest* version that
    // supports API 36, chosen over the latest 8.x deliberately: it is
    // the smallest move that unblocks the requirement, and it needs
    // Gradle >= 8.13, which the wrapper (8.14.3) already satisfies, so
    // the wrapper does not move with it.
    id("com.android.application") version "8.11.1" apply false
    kotlin("android") version "2.1.0" apply false
    kotlin("plugin.serialization") version "2.1.0" apply false
}
