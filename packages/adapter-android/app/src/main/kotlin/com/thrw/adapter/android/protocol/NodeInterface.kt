package com.thrw.adapter.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Mirror of `packages/protocol`'s `type Priority = number`. */
typealias Priority = Int

/**
 * Mirror of `packages/protocol`'s `EventKind` union - the trigger
 * categories from architecture.md's "Priority rules" section. The
 * `@SerialName` values are the wire format and must stay byte-identical to
 * the TypeScript union members `"call" | "manual_claim" | "voip" | "media"`.
 *
 * Note the *ranking* of these kinds is deliberately not mirrored here:
 * architecture.md requires priority rules to live server-side in the relay,
 * "never duplicated in adapters".
 */
@Serializable
enum class EventKind {
    @SerialName("call")
    CALL,

    @SerialName("manual_claim")
    MANUAL_CLAIM,

    @SerialName("voip")
    VOIP,

    @SerialName("media")
    MEDIA,
}

/** Mirror of `packages/protocol`'s `NodeManifest["platform"]` union. */
@Serializable
enum class Platform {
    @SerialName("android")
    ANDROID,

    @SerialName("mac")
    MAC,

    @SerialName("ipad")
    IPAD,

    @SerialName("linux")
    LINUX,
}

/**
 * Mirror of `packages/protocol`'s `NodeManifest` - same field names, same
 * order. This is what the relay's device registry
 * (`packages/relay-core/src/device-registry.ts`) stores verbatim, so the
 * JSON field names here have to match the TypeScript interface exactly.
 */
@Serializable
data class NodeManifest(
    val nodeId: String,
    val platform: Platform,
    val displayName: String,
    val adapterVersion: String,
    val supportedEventKinds: List<EventKind>,
)

/**
 * Mirror of `packages/protocol`'s `NodeInterface`, the shared node
 * interface from architecture.md's "System components" section.
 *
 * Deliberately *not* here: the connection state machine (idle / pre-claim /
 * claim / active). That is a frozen contract per ADR 0010 / 0011 / 0013 and
 * needs its own ADR plus human review - the TypeScript `NodeInterface`
 * leaves it out for the same reason.
 *
 * The one intentional difference from the TypeScript shape: these are
 * `suspend fun` rather than `void`-returning. Every one of them does I/O
 * (an MQTT publish, or a Bluetooth connect/disconnect through
 * `BluetoothConnectionManager`, whose methods are already `suspend`), and
 * AGENTS.md's conventions require Kotlin coroutines for async code.
 */
interface NodeInterface {
    suspend fun register(manifest: NodeManifest)

    suspend fun emitEvent(type: EventKind, priority: Priority)

    suspend fun onClaim()

    suspend fun onRelease()
}
