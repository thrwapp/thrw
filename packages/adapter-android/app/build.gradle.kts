import java.util.Properties

// Real Android Gradle Plugin module as of #96 - was previously a plain
// Kotlin/JVM placeholder scaffold ("swap to com.android.application once
// [the Android SDK is] provisioned in CI"). The swap landed as part of
// #96's composition-root wiring, since the foreground Service, the
// NotificationListenerService subclass, and the real android.bluetooth /
// android.telephony-backed seam implementations all need android.jar on
// the compile classpath. See docs/handoffs/96.md.
plugins {
    id("com.android.application")
    kotlin("android")
    kotlin("plugin.serialization")
}

android {
    namespace = "com.thrw.adapter.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.thrw.adapter.android"
        // TelephonyCallback (registerTelephonyCallback + CallStateListener,
        // see triggers/CallStateSource.kt) and CallStyle notifications'
        // EXTRA_CALL_TYPE (see triggers/NotificationSource.kt) both need
        // API 31. Reference hardware (architecture.md) is a Pixel 10 Pro on
        // Android 16 QPR3/17, well above that floor, so this issue doesn't
        // carry the deprecated PhoneStateListener fallback path for older
        // releases - a judgment call, documented in docs/handoffs/96.md.
        minSdk = 31
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        // Exposes AGP's own generated BuildConfig.VERSION_NAME, used as
        // NodeManifest.adapterVersion (see DeviceIdentity.kt) - a single
        // source of truth for the adapter's version rather than
        // duplicating `versionName` as a second literal somewhere else.
        // Distinct from, and doesn't collide with, this module's own
        // hand-generated com.thrw.adapter.android.config.BuildConfig
        // below (ADR 0005's RELAY_URL/LICENSING_URL/SELF_HOSTED).
        buildConfig = true
    }

    testOptions {
        unitTests {
            // Tests never call into real android.* code paths (they fake
            // the BluetoothClassicGateway/CallStateSource/NotificationSource
            // seams, same discipline as before AGP - see each seam's kdoc)
            // - this is a safety net against android.jar's stub methods
            // throwing if any incidental framework call (e.g. android.util.Log)
            // slips into a tested path, not a sign real framework classes are
            // meant to be exercised here. No Robolectric: not justified for
            // that alone (AGENTS.md - no new dependency without justification).
            isReturnDefaultValues = true
        }
    }

    packaging {
        resources {
            // Pre-existing, found while verifying #102's launcher activity
            // could actually be installed: `./gradlew build` (this module's
            // `pnpm build` script) fails in `mergeDebugJavaResource` with
            // "6 files found with path 'META-INF/INDEX.LIST'" - the six
            // io.netty jars hivemq-mqtt-client pulls in each ship one, and
            // APK packaging has no default rule for them. Reproduced on an
            // otherwise-clean tree with none of #102's changes applied, so
            // it predates this issue; CI's `android` job only runs
            // `./gradlew test`, which never packages, which is why it went
            // unnoticed. Excluded rather than picked/merged: these are JAR
            // index and build-metadata files with no meaning inside an APK.
            excludes += setOf(
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
                "META-INF/DEPENDENCIES",
            )
        }
    }
}

repositories {
    // AGP / androidx artifacts live on Google's Maven, not mavenCentral.
    google()
    mavenCentral()
}

dependencies {
    // Per AGENTS.md: "use Kotlin coroutines for async code" - the async
    // connect/disconnect calls in the bluetooth package are suspend
    // functions backed by this.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    // MQTT client (ADR 0001). HiveMQ rather than Eclipse Paho: it's a plain
    // Java library that runs both on this module's Kotlin/JVM scaffold and
    // on Android from the same artifact (Paho's Android client is an AAR
    // needing the Android Gradle Plugin, which this module doesn't use yet,
    // and eclipse/paho.mqtt.android is archived/unmaintained), and it
    // supports MQTT-over-WebSocket/TLS - ADR 0001's transport - natively.
    implementation("com.hivemq:hivemq-mqtt-client:1.3.3")

    // #102's ProvisioningActivity: ComponentActivity +
    // registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()),
    // the standard runtime-permission flow. The first androidx artifact in
    // this module, and pre-authorized by #102's acceptance criterion 6
    // ("no new dependency beyond Android's own androidx.activity/androidx.core
    // permission APIs"). Note this is the plain `activity` artifact, not
    // `activity-ktx`/`activity-compose`: the screen is platform views in an
    // XML layout, so nothing beyond ComponentActivity and the result
    // contracts is needed. androidx.core/lifecycle/savedstate come in
    // transitively as part of ComponentActivity, not as separate choices.
    implementation("androidx.activity:activity:1.9.3")

    // JSON for the wire payloads. Needed to encode the manifest's
    // free-text fields with correct escaping and to pin exact field names
    // (@SerialName) against the TypeScript shapes in packages/protocol and
    // packages/relay-core; kotlinx.serialization is the Kotlin-standard,
    // reflection-free (hence Android/R8-friendly) way to do that.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.3")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")

    // Embedded MQTT broker so the MQTT tests run against a real broker
    // speaking the real protocol, mirroring how packages/relay-core's tests
    // use a real Mosquitto. Moquette is in-process, so unlike Mosquitto it
    // needs no Docker/service container in the CI `android` job.
    testImplementation("io.moquette:moquette-broker:0.17")
    testRuntimeOnly("org.slf4j:slf4j-simple:2.0.16")
}

// ADR 0005: the relay URL and licensing endpoint are build-time
// configuration read from a per-adapter config file, never hardcoded inline
// in source. This generates the Android BuildConfig equivalent from
// ../config/adapter.properties - a self-hoster edits that file and rebuilds.
val adapterConfigFile = rootProject.file("config/adapter.properties")
val generatedConfigDir = layout.buildDirectory.dir("generated/source/adapterConfig")

val generateAdapterBuildConfig =
    tasks.register("generateAdapterBuildConfig") {
        val source = adapterConfigFile
        val outputDir = generatedConfigDir
        inputs.file(source)
        outputs.dir(outputDir)

        doLast {
            val properties = Properties()
            source.inputStream().use { properties.load(it) }

            fun required(key: String): String =
                requireNotNull(properties.getProperty(key)) {
                    "$key missing from ${source.name} - see ADR 0005"
                }

            val packageDir = outputDir.get().asFile.resolve("com/thrw/adapter/android/config")
            packageDir.mkdirs()
            packageDir.resolve("BuildConfig.kt").writeText(
                """
                |// GENERATED by the generateAdapterBuildConfig Gradle task from
                |// packages/adapter-android/config/adapter.properties. Do not edit
                |// by hand and do not commit - edit that properties file instead
                |// (ADR 0005: build-time configuration, not hardcoded endpoints).
                |package com.thrw.adapter.android.config
                |
                |object BuildConfig {
                |    const val RELAY_URL: String = "${required("relay.url")}"
                |    const val LICENSING_URL: String = "${required("licensing.url")}"
                |    const val SELF_HOSTED: Boolean = ${required("selfHosted").toBoolean()}
                |}
                |
                """.trimMargin(),
            )
        }
    }

android.sourceSets.getByName("main").kotlin.srcDir(generateAdapterBuildConfig)

// Unlike the Kotlin/JVM plugin's `kotlin.sourceSets`, wiring a generated
// dir into `android.sourceSets` above doesn't on its own add a task
// dependency - AGP's per-variant Kotlin compile tasks need telling
// explicitly, or they read the (not yet generated) source dir before this
// task has run.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    dependsOn(generateAdapterBuildConfig)
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
}
