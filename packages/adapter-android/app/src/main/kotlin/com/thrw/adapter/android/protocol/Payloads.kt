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

/**
 * Mirror of relay-core's `SequencedCommandPayload`.
 *
 * [seq] and [epoch] are nullable with a `null` default so a command that
 * carries neither still decodes. That is not defensive padding: the relay
 * half of #210 shipped before this half, so a build of this adapter has
 * already run against a relay that stamped nothing, and the
 * [CommandSequenceGate] treats an unsequenced command as acceptable
 * rather than discarding it.
 */
@Serializable
data class CommandPayload(
    val type: CommandType,
    /**
     * Monotonic per (account, node, resource type), within one [epoch].
     * See [CommandSequenceGate] for what this node does with it.
     */
    val seq: Long? = null,
    /**
     * The relay *process* that sent this. Changes on every relay
     * restart, which is what stops the high-water mark deadlocking the
     * system - see [CommandSequenceGate].
     */
    val epoch: String? = null,
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
    /**
     * This node's observed **audio route** per resource type (#191),
     * keyed by ADR 0015's resource-type vocabulary - only [RESOURCE_AUDIO]
     * exists today.
     *
     * Keyed rather than a bare boolean so it survives the ADR 0015
     * migration (#171) without a second payload change; that ADR is
     * accepted, so this is following it rather than speculating.
     *
     * A resource is **absent** when its route cannot be determined, or
     * while a claim or release is still settling. Absent means "no
     * information" and leaves the relay's record alone; `false` asserts
     * this node does not hold the resource and is grounds for corrective
     * action. Reporting a guess as `false` would hand the relay a
     * fabricated disagreement.
     */
    val observedRoutes: Map<String, Boolean> = emptyMap(),
)

/** ADR 0015's resource type for the headset audio connection. */
const val RESOURCE_AUDIO: String = "audio"

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

const val COMMAND_OUTCOME_KIND: String = "command_outcome"

/**
 * ADR 0019 / #206 stage 2. How a claim or release actually ended.
 *
 * Same `kind`-discriminator trick as [RegistrationPayload] and
 * [EventEndPayload], for the same reason: the topic set is frozen, so
 * this rides the events topic rather than getting one of its own.
 * Mirrors `packages/protocol`'s `CommandOutcomePayload` and
 * `adapter-mac`'s own copy - three hand-written implementations of one
 * wire format, and nothing else catches them drifting.
 *
 * `epoch` and `seq` identify *which* command this answers, reusing the
 * pair ADR 0018 point 1 added for idempotency (#210/#224). Nullable for
 * the same reason [CommandPayload]'s are: a command carrying neither is
 * still acted on, so an outcome for it must still be reportable.
 */
@Serializable
data class CommandOutcomePayload(
    val kind: String = COMMAND_OUTCOME_KIND,
    val epoch: String? = null,
    /** `Long` to match [CommandPayload.seq], which is what it echoes. */
    val seq: Long? = null,
    val resourceType: String,
    val outcome: String,
    val reason: String? = null,
    val durationMs: Long,
)

/** Mirror of `packages/protocol`'s `CommandOutcome`. */
enum class CommandOutcome(val wire: String) {
    SUCCEEDED("succeeded"),
    FAILED("failed"),
    TIMED_OUT("timed_out"),
}

/**
 * Mirror of `packages/protocol`'s `CommandFailureReason`.
 *
 * **Only two of the three are emitted today, deliberately.**
 * Distinguishing `bluetooth_unavailable` from
 * `target_device_unreachable` needs the gateways to surface typed,
 * *comparable* errors, and they do not: Android throws
 * `IllegalStateException` with prose in the message, macOS throws
 * `BluetoothGatewayError` cases about pairing. Classifying each platform
 * by whatever it happens to throw would make one reason code mean
 * different things on each side - and ADR 0019's premise is that an
 * outcome means the same thing in every row, or the aggregate is
 * meaningless.
 *
 * So both platforms report `target_device_unreachable` for any
 * non-timeout failure until the gateways can tell these apart. Coarse
 * and comparable beats precise and incomparable; typed gateway errors
 * are the follow-up that unlocks the finer split.
 */
enum class CommandFailureReason(val wire: String) {
    BLUETOOTH_UNAVAILABLE("bluetooth_unavailable"),
    TARGET_DEVICE_UNREACHABLE("target_device_unreachable"),
    SUPERSEDED_BY_NEWER_COMMAND("superseded_by_newer_command"),
}

/**
 * Lenient on decode so a relay that grows extra command fields later
 * doesn't break older adapters mid-rollout; strict-ish on encode (no
 * defaults omitted) so the `kind` discriminator is always on the wire.
 */
val ProtocolJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}
