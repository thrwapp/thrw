package com.thrw.adapter.android.protocol

/**
 * Kotlin mirror of `packages/protocol/src/index.ts`'s MQTT topic builders -
 * see docs/spec/architecture.md, "MQTT topic design".
 *
 * The topic structure itself is a frozen contract (AGENTS.md, ADR 0001);
 * changing the string shapes below requires a new ADR and human review.
 * These are re-implemented rather than imported because the TypeScript
 * package can't be consumed from Kotlin - so the *only* discipline that
 * keeps the two in sync is that every publish/subscribe in this adapter
 * goes through this object, never a literal topic string at the call site.
 */
object Topics {
    fun events(account: String, node: String): String = "thrw/$account/nodes/$node/events"

    fun commands(account: String, node: String): String = "thrw/$account/commands/$node"

    fun state(account: String): String = "thrw/$account/state"

    fun heartbeat(account: String, node: String): String = "thrw/$account/nodes/$node/heartbeat"
}

/**
 * Kotlin mirror of `packages/protocol`'s `TopicQos` constant: events QoS 1,
 * commands QoS 1, state retained, heartbeat QoS 0. Same frozen-contract
 * caveat as [Topics] - these values come from architecture.md's "MQTT topic
 * design" section and ADR 0001, not from this adapter.
 */
object TopicQos {
    const val EVENTS_QOS: Int = 1
    const val COMMANDS_QOS: Int = 1
    const val STATE_RETAINED: Boolean = true
    const val HEARTBEAT_QOS: Int = 0
}
