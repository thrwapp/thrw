package com.thrw.adapter.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Wire payloads carried on the topics in [Topics].
 *
 * architecture.md and `packages/protocol` define the *topics*, not the
 * message bodies on them - the bodies were decided per-issue. [EventPayload]
 * and [CommandPayload] below are exact mirrors of the shapes
 * `packages/relay-core/src/mqtt-client.ts` already publishes/consumes, so
 * this adapter is wire-compatible with the relay as it exists today.
 * [RegistrationPayload] is new - see docs/handoffs/67.md for why it rides
 * the events topic with a `kind` discriminator rather than getting a topic
 * of its own (the topic set is frozen).
 */

/** Mirror of relay-core's `EventPayload`. */
@Serializable
data class EventPayload(
    val type: EventKind,
    val priority: Priority,
)

/** Mirror of relay-core's `CommandPayload["type"]` union. */
@Serializable
enum class CommandType {
    @SerialName("claim")
    CLAIM,

    @SerialName("release")
    RELEASE,
}

/** Mirror of relay-core's `CommandPayload`. */
@Serializable
data class CommandPayload(
    val type: CommandType,
)

/**
 * Registration envelope published on the node's own events topic. The
 * `kind` discriminator is what distinguishes it from an [EventPayload] on
 * that same topic: a registration has `kind`, an event does not (and an
 * event's `type` is always an [EventKind], never `"register"`), so adding
 * this can't change how an existing event message parses.
 */
@Serializable
data class RegistrationPayload(
    val kind: String = REGISTRATION_KIND,
    val manifest: NodeManifest,
)

const val REGISTRATION_KIND: String = "register"

/**
 * Lenient on decode so a relay that grows extra command fields later
 * doesn't break older adapters mid-rollout; strict-ish on encode (no
 * defaults omitted) so the `kind` discriminator is always on the wire.
 */
val ProtocolJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}
