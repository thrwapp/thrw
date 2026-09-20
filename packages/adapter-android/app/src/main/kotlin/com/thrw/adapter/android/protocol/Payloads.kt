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
    /**
     * The triggers this node has active *right now* (#178).
     *
     * Registration is re-sent periodically, not only at startup, and
     * carrying the active set is what lets a relay that restarted - or
     * whose MQTT connection dropped and reconnected - recover a correct
     * picture. Without it the relay would have to infer state from a
     * stream of edges it may have missed entirely, and a node that is
     * mid-playback would stay invisible until it happened to stop.
     *
     * Sent on every registration, including the first, where it is empty.
     */
    val activeEvents: List<EventKind> = emptyList(),
)

const val REGISTRATION_KIND: String = "register"

/**
 * "The trigger I reported earlier stopped", published on the node's own
 * events topic. New here (#68) - see docs/handoffs/68.md.
 *
 * Nothing on the wire carried this yet: relay-core publishes/consumes only
 * [EventPayload] (start) and [CommandPayload]. But relay-core's
 * `PriorityEngine` already has `endEvent(nodeId, type)` alongside
 * `recordEvent(nodeId, type)`, and architecture.md's "Priority rules"
 * section hangs auto-return off `call_ended`, so the *engine* expects this
 * signal - only the message shape was missing.
 *
 * Same `kind`-discriminator trick as [RegistrationPayload], and for the
 * same reason (the topic set is frozen, so this rides the events topic).
 * It carries no `priority`: ending a trigger needs only its kind, which is
 * all `PriorityEngine.endEvent` takes.
 */
@Serializable
data class EventEndPayload(
    val kind: String = EVENT_END_KIND,
    val type: EventKind,
)

const val EVENT_END_KIND: String = "event_end"

/**
 * Lenient on decode so a relay that grows extra command fields later
 * doesn't break older adapters mid-rollout; strict-ish on encode (no
 * defaults omitted) so the `kind` discriminator is always on the wire.
 */
val ProtocolJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}
