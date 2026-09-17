plugins {
    // #96: AGP swap - real android.app.Service / NotificationListenerService /
    // android.bluetooth / android.telephony implementations can't compile
    // against the plain Kotlin/JVM scaffold this module used to be (see
    // docs/handoffs/66.md's "Uncertain / judgment calls" for the original
    // deferral, docs/handoffs/96.md for this swap). Versions declared here
    // (`apply false`), applied per-module below.
    id("com.android.application") version "8.7.3" apply false
    kotlin("android") version "2.1.0" apply false
    kotlin("plugin.serialization") version "2.1.0" apply false
}
