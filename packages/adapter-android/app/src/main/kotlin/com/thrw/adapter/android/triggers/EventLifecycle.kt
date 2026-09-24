package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.NodeInterface
import com.thrw.adapter.android.protocol.Priority

/**
 * What the trigger detectors in this package need from a node: start a
 * trigger, and later say it stopped.
 *
 * [NodeInterface] (the Kotlin mirror of `packages/protocol`'s frozen type)
 * only has `emitEvent` - it has no symmetric end signal, which the
 * detectors here need: a call ends, a VoIP session ends, and the relay has
 * to hear about it. `packages/relay-core`'s `PriorityEngine` already
 * *expects* to hear about it - it exposes `recordEvent(nodeId, type)` and
 * `endEvent(nodeId, type)` (packages/relay-core/src/index.ts), and
 * architecture.md's "Priority rules" section hangs auto-return off
 * `call_ended` - but no MQTT message shape carries it yet.
 *
 * So [endEvent] is added here, on the adapter side only, named to match
 * relay-core's own method. Deliberately *not* added to
 * `protocol/NodeInterface.kt` or to `packages/protocol`: that type is the
 * frozen cross-platform contract, and growing it is an ADR plus human
 * review (AGENTS.md), not a routine agent PR. When that ADR happens,
 * `NodeInterface` grows `endEvent` and this interface can go away.
 */
interface EventLifecycle {
    /** A trigger of [type] just started on this node. */
    suspend fun emitEvent(type: EventKind, priority: Priority)

    /** The [type] trigger that was active on this node just stopped. */
    suspend fun endEvent(type: EventKind)

    /**
     * Whether [type] is currently one of this node's active triggers
     * (#234).
     *
     * Not `suspend`: it reads state the node already keeps for
     * `RegistrationPayload.activeEvents`, so there is nothing to await.
     * [com.thrw.adapter.android.claim.ManualClaim] reads this instead of
     * tracking its own copy - see that class for what the second copy
     * cost.
     */
    fun isEventActive(type: EventKind): Boolean
}

/**
 * The priority these detectors report on every event.
 *
 * Adapters do not rank triggers: "Priority rules live server-side in the
 * relay, never duplicated in adapters" (architecture.md), and relay-core's
 * `PriorityEngine` ranks purely by [EventKind] against `PRIORITY_ORDER` -
 * it never reads this field. But `EventPayload.priority` exists on the
 * wire, so something has to go in it. This constant is that something: one
 * value for every kind, so no ranking is implied by, or can drift in, this
 * adapter.
 */
const val UNRANKED_PRIORITY: Priority = 0
