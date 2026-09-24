package com.thrw.adapter.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

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
/**
 * ADR 0015's resource types. Mirrors `@thrw/protocol`'s `ResourceType`;
 * the wire spellings are pinned by
 * `packages/protocol/fixtures/topics.json`, which this module's own
 * tests assert against - there are three hand-written implementations of
 * the topic contract and nothing else would catch them drifting apart.
 */
@Serializable
enum class ResourceType {
    @SerialName("audio")
    AUDIO,

    @SerialName("hid")
    HID,
    ;

    /** The wire spelling - lowercase, as it appears in a topic. */
    val wire: String get() = name.lowercase()
}

object Topics {
    fun events(account: String, node: String, resource: ResourceType): String =
        "thrw/$account/nodes/$node/${resource.wire}/events"

    fun commands(account: String, node: String, resource: ResourceType): String =
        "thrw/$account/commands/$node/${resource.wire}"

    fun state(account: String, resource: ResourceType): String = "thrw/$account/state/${resource.wire}"

    /**
     * Deliberately **without** a resource segment (ADR 0015 lists exactly
     * three topics that gain one). Liveness is a property of the node,
     * not of any resource it manages.
     */
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

    /**
     * The QoS this adapter *subscribes* to the state topic at (#234).
     *
     * Not a mirror of anything, because there is nothing to mirror:
     * `packages/protocol`'s `TopicQos.state` specifies only
     * `{ retained: true }`, and `relay-core`'s `publishState` passes no
     * QoS, so the relay publishes at 0. A subscription is delivered at
     * the lower of the two levels, so asking for 1 here would buy
     * nothing while implying a guarantee the publisher does not make.
     *
     * Losing an update is tolerable on this topic in a way it would not
     * be on commands: the value is retained, so a reconnecting
     * subscriber is re-sent the current holder immediately.
     *
     * If `packages/protocol` ever pins a QoS for state, this becomes a
     * mirror of it and stops being a local decision.
     */
    const val STATE_SUBSCRIBE_QOS: Int = 0
}
