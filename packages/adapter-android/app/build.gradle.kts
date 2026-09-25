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

// Play permanently burns each versionCode on upload and rejects any repeat,
// so it can't be a hand-edited literal anyone has to remember to bump (#153).
// CI derives it from the commit count and passes it in; a local build falls
// back to 1, which is safe precisely because local builds are never uploaded
// - and if one ever is, Play rejecting it is the correct outcome.
//
// Deliberately not silently coerced: a malformed value here would produce an
// artifact whose version ordering is wrong in a way nobody notices until
// Play refuses a later upload.
val releaseVersionCode: Int = System.getenv("THRW_VERSION_CODE")?.let { raw ->
    requireNotNull(raw.toIntOrNull()) { "THRW_VERSION_CODE must be an integer, got: '$raw'" }
} ?: 1

// Upload-key material for Play Store releases (#132). Never committed: it
// comes from a gitignored keystore.properties next to config/, or from
// environment variables so CI can supply it from secrets instead of a file.
//
// Play App Signing means this is the *upload* key, not the app signing key
// Google holds - losing it is recoverable through Play Console, but it still
// must not end up in the repo.
//
// Absent entirely (the normal case: CI, a fresh clone, the agent pipeline),
// release builds stay unsigned rather than failing - `bundleRelease` is
// expected to work without it, and an unsigned bundle is a perfectly valid
// thing to produce locally. Only an *incomplete* configuration is an error,
// since that silently yields an artifact Play would reject.
//
// Env vars are namespaced THRW_PLAY_* because CI secrets share one flat
// namespace across every platform this repo ships (#153). The Mac/iPad
// release flow will need its own unrelated material - signing certificate,
// team id, App Store Connect API key - which belongs under THRW_APPLE_*
// rather than competing for generic names like THRW_UPLOAD_*. The
// keystore.properties *keys* stay unprefixed: that file lives inside
// packages/adapter-android, so it has no such ambiguity to resolve.
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

fun uploadKeyValue(propertyName: String, environmentName: String): String? =
    keystoreProperties.getProperty(propertyName) ?: System.getenv(environmentName)

val uploadStoreFile = uploadKeyValue("storeFile", "THRW_PLAY_KEYSTORE_FILE")
val uploadStorePassword = uploadKeyValue("storePassword", "THRW_PLAY_KEYSTORE_PASSWORD")
val uploadKeyAlias = uploadKeyValue("keyAlias", "THRW_PLAY_KEY_ALIAS")
val uploadKeyPassword = uploadKeyValue("keyPassword", "THRW_PLAY_KEY_PASSWORD")

val uploadKeyConfigured = uploadStoreFile != null

if (uploadKeyConfigured) {
    val missing = buildList {
        if (uploadStorePassword == null) add("storePassword/THRW_PLAY_KEYSTORE_PASSWORD")
        if (uploadKeyAlias == null) add("keyAlias/THRW_PLAY_KEY_ALIAS")
        if (uploadKeyPassword == null) add("keyPassword/THRW_PLAY_KEY_PASSWORD")
    }
    require(missing.isEmpty()) {
        "Upload key is partially configured - missing ${missing.joinToString(", ")}. " +
            "Set all four (see docs/handoffs/148.md), or none to build unsigned."
    }
}

android {
    namespace = "com.thrw.adapter.android"
    compileSdk = 36

    // Pinned rather than left to AGP's default (#237). Both workflows
    // hand-roll the SDK install and name an exact build-tools version,
    // and release-android.yml additionally builds a path to `apksigner`
    // out of it - so the version needs to be stated in one place they
    // can be checked against, which their own comments already assume
    // is this file.
    buildToolsVersion = "36.0.0"

    defaultConfig {
        // Play Store identity (#132) - deliberately distinct from `namespace`
        // above, which stays com.thrw.adapter.android (the Kotlin package
        // every source file already lives under; changing it would mean
        // moving every file, not a one-line config edit). applicationId has
        // no such constraint - it's purely the manifest/Play Console
        // identity, free to differ from the source package. Set to
        // app.thrw.android to match app.thrw.mac's reverse-DNS-of-thrw.app
        // convention (docs/handoffs/132.md), decided before this app's
        // first Play Store publish since it's effectively immutable after.
        applicationId = "app.thrw.android"
        // TelephonyCallback (registerTelephonyCallback + CallStateListener,
        // see triggers/CallStateSource.kt) and CallStyle notifications'
        // EXTRA_CALL_TYPE (see triggers/NotificationSource.kt) both need
        // API 31. Reference hardware (architecture.md) is a Pixel 10 Pro on
        // Android 16 QPR3/17, well above that floor, so this issue doesn't
        // carry the deprecated PhoneStateListener fallback path for older
        // releases - a judgment call, documented in docs/handoffs/96.md.
        minSdk = 31
        // 36 since #237: Play rejects anything lower for a new app as of
        // 31 August 2026, including on the internal testing track. See
        // that issue for the Android 16 targeting changes that were
        // checked against this code and found not to apply - the short
        // version is that edge-to-edge enforcement and the
        // BOOT_COMPLETED foreground-service restrictions both began at
        // targetSdk 35, which this already was.
        targetSdk = 36
        versionCode = releaseVersionCode
        // Bump in the same PR as the tag this ships under. v0.1.0's tag
        // exists precisely because this read 0.1.0 since #96 while every
        // build was tagged v0.0.1, so the version the relay saw in
        // NodeManifest.adapterVersion was not the version on the release
        // page. adapter-mac's DeviceIdentity.adapterVersion is the same
        // literal on the other side of the same contract - change both.
        versionName = "0.2.3"
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

    signingConfigs {
        if (uploadKeyConfigured) {
            create("upload") {
                storeFile = file(uploadStoreFile!!)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Only wired up when the upload key is actually available (see
            // the block above the `android {}` block). Left null otherwise,
            // which produces an unsigned release bundle rather than failing
            // the build - `signingConfig = signingConfigs.getByName("debug")`
            // would be worse than useless here, since a debug-signed AAB
            // looks publishable right up until Play rejects it.
            signingConfig = if (uploadKeyConfigured) signingConfigs.getByName("upload") else null
        }
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
            // hivemq-mqtt-client's Netty dependencies each ship their own
            // copy of these two META-INF files, so AGP's resource merger
            // can't pick one without this (#131). Neither is read by
            // Netty's own runtime behavior:
            // - INDEX.LIST: a JAR-indexing-era lookup optimization (pre-JPMS,
            //   from the old java.net.URLClassLoader "Class-Path" mechanism);
            //   the JVM falls back to normal classpath scanning when it's
            //   absent.
            // - io.netty.versions.properties: per-module version/commit
            //   metadata, read only by io.netty.util.Version.identify() for
            //   diagnostic banners - nothing in this adapter calls it.
            // Excluded outright, not picked-first: keeping one arbitrary
            // copy would give no benefit, since each is meaningless without
            // the specific jar it was generated for.
            excludes += "META-INF/INDEX.LIST"
            excludes += "META-INF/io.netty.versions.properties"
        }
    }
}

repositories {
    // AGP / androidx artifacts live on Google's Maven, not mavenCentral.
    google()
    mavenCentral()
}

dependencies {
    // ComponentActivity + registerForActivityResult /
    // ActivityResultContracts.RequestMultiplePermissions, the platform's
    // standard runtime-permission flow used by ui/ProvisioningActivity
    // (#102). The framework's own Activity has no registerForActivityResult,
    // only the deprecated onRequestPermissionsResult callback - this is the
    // supported API, and #102 names it explicitly. Nothing else from
    // androidx is pulled in deliberately (no AppCompat, no Material): the
    // provisioning screen is plain platform widgets.
    implementation("androidx.activity:activity:1.9.3")

    // NotificationManagerCompat.getEnabledListenerPackages(context), the
    // standard way to check the notification-listener special access
    // ui/ProvisioningActivity's status line reads (#107) - there's no
    // checkSelfPermission equivalent for it. Not a new dependency in
    // practice: androidx.activity:1.9.3 above already pulls in
    // androidx.core transitively (#102's handoff), this just declares the
    // direct compile-time use explicitly rather than relying on that being
    // true.
    implementation("androidx.core:core:1.13.1")

    // Netty's WebSocket implementation, required by hivemq-mqtt-client for
    // ADR 0001's ws://-and-wss:// transport. HiveMQ treats WebSocket support
    // as optional and does NOT declare this itself - its POM pulls in
    // netty-buffer/codec/handler/transport but not netty-codec-http, which
    // is where WebSocketClientHandshaker lives.
    //
    // Without it the app has no WebSocket implementation at all, and a
    // connect to a ws:// or wss:// broker HANGS FOREVER rather than
    // failing: the handshake dies inside Netty's pipeline and the connect
    // future is never completed. That is #158, and it cost a full
    // real-device debugging session.
    //
    // This was invisible because HiveMqttTransportTest runs against
    // embedded Moquette, which depends on netty-codec-http transitively -
    // so the test classpath had it and the app classpath never did. The
    // WebSocket test passed for the wrong reason. Version pinned to match
    // the other Netty modules hivemq-mqtt-client resolves (4.1.99.Final)
    // rather than floating, since mixing Netty module versions is its own
    // class of runtime failure.
    implementation("io.netty:netty-codec-http:4.1.99.Final")

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
        // Optional, so `inputs.files` rather than `inputs.file` - Gradle
        // would otherwise cache straight past a credential change.
        inputs.files(source.resolveSibling("adapter.local.properties"))
        outputs.dir(outputDir)

        doLast {
            val properties = Properties()
            source.inputStream().use { properties.load(it) }
            // #147: untracked overlay (config/adapter.local.properties,
            // gitignored) wins over the committed file. That's how the
            // relay's MQTT credential reaches the build without ever
            // being committed - see adapter.properties' own comment.
            val localSource = source.resolveSibling("adapter.local.properties")
            if (localSource.exists()) {
                localSource.inputStream().use { properties.load(it) }
            }

            fun required(key: String): String =
                requireNotNull(properties.getProperty(key)) {
                    "$key missing from ${source.name} - see ADR 0005"
                }

            // Credentials are legitimately absent: a local broker with
            // allow_anonymous on needs none, and that's how this module's
            // tests run. Empty means "connect anonymously".
            fun optional(key: String): String = properties.getProperty(key).orEmpty()

            // A credential is arbitrary text; a quote or backslash must
            // not break out of the Kotlin string literal below.
            fun escape(value: String): String = value.replace("\\", "\\\\").replace("\"", "\\\"")

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
                |    /** Empty when unset - see RelayCredentials.fromBuildConfig(). */
                |    const val RELAY_USERNAME: String = "${escape(optional("relay.username"))}"
                |    const val RELAY_PASSWORD: String = "${escape(optional("relay.password"))}"
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
