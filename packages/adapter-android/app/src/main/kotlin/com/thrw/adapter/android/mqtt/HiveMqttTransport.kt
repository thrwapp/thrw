package com.thrw.adapter.android.mqtt

import com.hivemq.client.mqtt.MqttWebSocketConfig
import com.hivemq.client.mqtt.datatypes.MqttQos
import com.hivemq.client.mqtt.mqtt3.Mqtt3BlockingClient
import com.hivemq.client.mqtt.mqtt3.Mqtt3Client
import com.thrw.adapter.android.config.RelayConfig
import com.thrw.adapter.android.config.RelayCredentials
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext

/**
 * [MqttTransport] backed by the HiveMQ MQTT client.
 *
 * MQTT 3.1.1 rather than 5, to match the rest of the system: the relay
 * side (`packages/relay-core/src/mqtt-client.ts`) uses the `mqtt` npm
 * package, whose default `protocolVersion` is 4 (= 3.1.1). ADR 0001
 * specifies the transport, QoS and retained semantics, none of which need
 * MQTT 5.
 *
 * Transport is MQTT over WebSocket/TLS per ADR 0001 whenever the
 * build-time-configured relay URL says so ([RelayConfig.webSocket] /
 * [RelayConfig.tls]) - which the shipped
 * `config/adapter.properties` (`wss://`) does.
 *
 * The HiveMQ client's own calls are blocking, so every one of them is
 * wrapped in `withContext(Dispatchers.IO)` rather than run on the caller's
 * (on Android, potentially main) thread.
 */
class HiveMqttTransport private constructor(
    private val client: Mqtt3BlockingClient,
) : MqttTransport {

    override suspend fun publish(topic: String, payload: String, qos: Int, retained: Boolean) {
        withContext(Dispatchers.IO) {
            client.publishWith()
                .topic(topic)
                .qos(mqttQos(qos))
                .retain(retained)
                .payload(payload.toByteArray(Charsets.UTF_8))
                .send()
        }
    }

    override fun subscribe(topic: String, qos: Int): Flow<String> = callbackFlow {
        val async = client.toAsync()
        async.subscribeWith()
            .topicFilter(topic)
            .qos(mqttQos(qos))
            .callback { publish -> trySend(String(publish.payloadAsBytes, Charsets.UTF_8)) }
            .send()
            .get()

        awaitClose {
            runCatching { async.unsubscribeWith().topicFilter(topic).send() }
        }
    }.flowOn(Dispatchers.IO)

    override suspend fun close() {
        withContext(Dispatchers.IO) { client.disconnect() }
    }

    companion object {
        private fun mqttQos(qos: Int): MqttQos =
            requireNotNull(MqttQos.fromCode(qos)) { "Not a valid MQTT QoS level: $qos" }

        /**
         * Connects to [config]'s relay as [clientId] and returns a
         * connected transport.
         *
         * [clientId] is the node id: the broker's account-scoped ACLs
         * (architecture.md, "MQTT topic design") key off the connecting
         * client, so it must not be randomly generated per process.
         */
        suspend fun connect(
            config: RelayConfig,
            clientId: String,
            credentials: RelayCredentials? = null,
        ): HiveMqttTransport = withContext(Dispatchers.IO) {
            var builder = Mqtt3Client.builder()
                .identifier(clientId)
                .serverHost(config.host)
                .serverPort(config.port)

            if (config.webSocket) {
                builder = builder.webSocketConfig(
                    MqttWebSocketConfig.builder().serverPath(config.webSocketPath).build(),
                )
            }
            if (config.tls) {
                builder = builder.sslWithDefaultConfig()
            }

            val client = builder.buildBlocking()
            // #147: null connects anonymously, which is correct for a
            // local broker with allow_anonymous on (how this module's
            // tests run). The deployed relay sets allow_anonymous=false
            // and rejects that with a NOT_AUTHORIZED connack.
            if (credentials != null) {
                client.toBlocking().connectWith()
                    .simpleAuth()
                    .username(credentials.username)
                    .password(credentials.password.toByteArray())
                    .applySimpleAuth()
                    .send()
            } else {
                client.connect()
            }
            HiveMqttTransport(client)
        }
    }
}
