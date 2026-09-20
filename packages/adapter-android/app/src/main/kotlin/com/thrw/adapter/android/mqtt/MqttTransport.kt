package com.thrw.adapter.android.mqtt

import kotlinx.coroutines.flow.Flow

/**
 * The seam between the node interface and whichever MQTT client library is
 * underneath it. Deliberately narrow: publish a payload on a topic at a
 * QoS, subscribe to a topic at a QoS, close.
 *
 * It takes topics and QoS numbers rather than deriving them, so that every
 * topic string in this adapter comes from
 * `com.thrw.adapter.android.protocol.Topics` and every QoS from `TopicQos`
 * (the same discipline `packages/relay-core`'s `RelayMqttClient` enforces
 * on the TypeScript side). Tests fake this interface; [HiveMqttTransport]
 * is the real implementation.
 */
interface MqttTransport {
    suspend fun publish(topic: String, payload: String, qos: Int, retained: Boolean = false)

    /**
     * Cold flow of payloads on [topic]. The MQTT subscription is opened
     * when the flow is collected and unsubscribed when collection stops.
     */
    fun subscribe(topic: String, qos: Int): Flow<String>

    suspend fun close()

    /**
     * Registers [handler] to run whenever the transport **re-establishes**
     * a dropped connection - not on the first connect (#182).
     *
     * The node uses this to re-register, because the relay learns of a
     * node only from a registration and holds that in memory: a node that
     * silently reconnects is connected but invisible, which is #178 by
     * another route. Reconnect is also precisely when the relay's picture
     * is most likely to be stale, and #178 made registration a safe,
     * repeatable statement of current state rather than an edge.
     *
     * Default no-op so the fakes in this module's tests, and any
     * transport without a reconnect story, need no change.
     */
    fun onReconnected(handler: () -> Unit) {}

    /**
     * Whether the transport currently has a live connection (#213).
     *
     * Used to tell "not holding the headset" apart from "not talking to
     * the relay at all", which from outside look identical and have
     * looked identical during every silent failure so far (#173, #178,
     * #182).
     *
     * Defaults to `true`: a transport that does not track connection
     * state has no way to be *known* disconnected, and defaulting to
     * false would put every test fake permanently into "disconnected".
     */
    fun isConnected(): Boolean = true
}
