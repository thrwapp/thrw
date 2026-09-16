// Placeholder: plain Kotlin/JVM module, not the Android Gradle Plugin. This
// scaffold exists to prove the polyglot task graph works before the Android
// SDK is provisioned in CI; swap to com.android.application once it is.
plugins {
    kotlin("jvm") version "2.1.0"
}

repositories {
    mavenCentral()
}

dependencies {
    // Per AGENTS.md: "use Kotlin coroutines for async code" - the async
    // connect/disconnect calls in the bluetooth package are suspend
    // functions backed by this.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.3")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

tasks.test {
    useJUnitPlatform()
}
