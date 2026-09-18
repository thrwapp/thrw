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
import kotlinx.coroutines.withTimeout

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
        /**
         * How long to wait for a broker to complete the MQTT connect
         * before giving up (#158).
         *
         * HiveMQ's blocking connect has no timeout of its own: if the
         * transport-level handshake never completes, it waits forever.
         * That is exactly what happened on a real device when
         * `netty-codec-http` was missing - a foreground service with a
         * live TLS socket and no MQTT session, indistinguishable from
         * "still connecting", for as long as the app ran. A bounded wait
         * turns any future variant of that into a loud, diagnosable
         * failure instead of a silent hang.
         */
        private const val CONNECT_TIMEOUT_MS = 20_000L

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
            // withTimeout rather than a HiveMQ-level option: the blocking
            // connect below offers none. Cancellation can't interrupt the
            // blocking call itself, but it does free the caller and
            // surfaces a TimeoutCancellationException the service logs,
            // which is the difference between a diagnosable failure and
            // an invisible one.
            // #147: null connects anonymously, which is correct for a
            // local broker with allow_anonymous on (how this module's
            // tests run). The deployed relay sets allow_anonymous=false
            // and rejects that with a NOT_AUTHORIZED connack.
            withTimeout(CONNECT_TIMEOUT_MS) {
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
            }
            HiveMqttTransport(client)
        }
    }
}
