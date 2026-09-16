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
}
