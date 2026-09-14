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
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.3")
}

tasks.test {
    useJUnitPlatform()
}
