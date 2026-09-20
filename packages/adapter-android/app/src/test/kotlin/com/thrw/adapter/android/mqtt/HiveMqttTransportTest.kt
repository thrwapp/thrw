package com.thrw.adapter.android.mqtt

import com.hivemq.client.mqtt.MqttGlobalPublishFilter
import com.hivemq.client.mqtt.MqttWebSocketConfig
import com.hivemq.client.mqtt.datatypes.MqttQos
import com.hivemq.client.mqtt.mqtt3.Mqtt3BlockingClient
import com.hivemq.client.mqtt.mqtt3.Mqtt3Client
import com.thrw.adapter.android.AndroidNode
import com.thrw.adapter.android.bluetooth.BluetoothClassicGateway
import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.config.RelayConfig
import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.protocol.Platform
import com.thrw.adapter.android.protocol.ProtocolJson
import com.thrw.adapter.android.protocol.ResourceType
import com.thrw.adapter.android.protocol.Topics
import com.thrw.adapter.android.protocol.TopicQos
import io.moquette.broker.Server
import io.moquette.broker.config.MemoryConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.ServerSocket
import java.util.Properties
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * End-to-end against a **real MQTT broker** speaking the real protocol -
 * the same shape of coverage `packages/relay-core`'s tests get from a real
 * Mosquitto. Moquette is embedded in-process rather than a container so the
 * CI `android` job (`.github/workflows/ci.yml`) needs no extra service.
 *
 * What this does *not* cover: TLS. The broker here speaks `ws://`, not
 * `wss://` - see docs/handoffs/67.md.
 */
class HiveMqttTransportTest {
    private lateinit var broker: Server
    private lateinit var config: RelayConfig
    private val closeables = mutableListOf<() -> Unit>()

    @BeforeTest
    fun startBroker() {
        val webSocketPort = freePort()
        val properties = Properties().apply {
            setProperty("host", HOST)
            // Disable the plain-TCP listener: ADR 0001's transport is
            // MQTT over WebSocket, so that's the only one under test.
            setProperty("port", "disabled")
            setProperty("websocket_port", webSocketPort.toString())
            setProperty("websocket_path", "/mqtt")
            setProperty("allow_anonymous", "true")
            setProperty("persistence_enabled", "false")
        }

        broker = Server()
        broker.startServer(MemoryConfig(properties))
        config = RelayConfig.fromUrl("ws://$HOST:$webSocketPort/mqtt")
    }

    @AfterTest
    fun stopBroker() {
        closeables.forEach { runCatching { it() } }
        closeables.clear()
        broker.stopServer()
    }

    @Test
    fun `the transport really connects over WebSocket and publishes at the requested QoS`() = runBlocking {
        val relay = connectRelayClient()
        val received = relay.publishes(MqttGlobalPublishFilter.ALL)
        relay.subscribeWith().topicFilter(EVENTS_TOPIC).qos(MqttQos.AT_LEAST_ONCE).send()

        val transport = connectTransport()
        transport.publish(EVENTS_TOPIC, """{"type":"call","priority":1}""", TopicQos.EVENTS_QOS, false)

        val publish = received.receive(TIMEOUT_SECONDS, TimeUnit.SECONDS).orElseThrow()
        assertEquals(EVENTS_TOPIC, publish.topic.toString())
        assertEquals(MqttQos.AT_LEAST_ONCE, publish.qos)
        assertEquals("""{"type":"call","priority":1}""", String(publish.payloadAsBytes))
    }

    @Test
    fun `register and emitEvent land on the node's events topic at QoS 1`() = runBlocking {
        val relay = connectRelayClient()
        val received = relay.publishes(MqttGlobalPublishFilter.ALL)
        relay.subscribeWith().topicFilter(EVENTS_TOPIC).qos(MqttQos.AT_LEAST_ONCE).send()

        val node = AndroidNode(ACCOUNT, NODE, HEADSET, connectTransport(), BluetoothConnectionManager(RecordingGateway()))
        node.register(MANIFEST)
        node.emitEvent(EventKind.VOIP, 3)

        val registration = received.receive(TIMEOUT_SECONDS, TimeUnit.SECONDS).orElseThrow()
        assertEquals(EVENTS_TOPIC, registration.topic.toString())
        assertEquals(MqttQos.AT_LEAST_ONCE, registration.qos)
        val body = ProtocolJson.parseToJsonElement(String(registration.payloadAsBytes)) as JsonObject
        assertEquals("register", body.getValue("kind").jsonPrimitive.content)
        assertEquals(
            NODE,
            (body.getValue("manifest") as JsonObject).getValue("nodeId").jsonPrimitive.content,
        )

        val event = received.receive(TIMEOUT_SECONDS, TimeUnit.SECONDS).orElseThrow()
        assertEquals(MqttQos.AT_LEAST_ONCE, event.qos)
        assertEquals("""{"type":"voip","priority":3}""", String(event.payloadAsBytes))
    }

    @Test
    fun `a claim then release command from the relay drives the Bluetooth connection manager`() = runBlocking {
        val gateway = RecordingGateway()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, connectTransport(), BluetoothConnectionManager(gateway))
        val relay = connectRelayClient()

        val listener = launch(Dispatchers.IO) { node.listenForCommands() }
        try {
            // The node's subscription is established asynchronously, and a
            // QoS 1 message published before it lands has nowhere to go -
            // so republish until it's observed rather than sleeping a
            // guessed interval. Repeats are harmless: BluetoothConnectionManager
            // treats a second claim for an already-connected device as a no-op.
            publishUntil(relay, """{"type":"claim"}""") { gateway.connectCalls.isNotEmpty() }
            assertEquals(listOf(HEADSET), gateway.connectCalls.toList())

            publishUntil(relay, """{"type":"release"}""") { gateway.disconnectCalls.isNotEmpty() }
            assertEquals(listOf(HEADSET), gateway.disconnectCalls.toList())
        } finally {
            listener.cancel()
        }
    }

    @Test
    fun `a retained publish is delivered to a subscriber that connects afterwards`() = runBlocking {
        val transport = connectTransport()
        transport.publish(Topics.state(ACCOUNT, ResourceType.AUDIO), """{"holder":"$NODE"}""", 1, TopicQos.STATE_RETAINED)

        val lateJoiner = connectRelayClient("late-joiner")
        val received = lateJoiner.publishes(MqttGlobalPublishFilter.ALL)
        lateJoiner.subscribeWith().topicFilter(Topics.state(ACCOUNT, ResourceType.AUDIO)).qos(MqttQos.AT_LEAST_ONCE).send()

        // Receiving at all is the assertion: this subscriber connected
        // *after* the publish, so the only way this message reaches it is
        // out of the broker's retained store - which is what architecture.md
        // relies on for "a reconnecting node immediately knows who currently
        // holds the connection". (Not asserted: the RETAIN flag on the
        // delivered message. Moquette doesn't set it when replaying from its
        // retained store, so that would test the broker, not this adapter.)
        val publish = received.receive(TIMEOUT_SECONDS, TimeUnit.SECONDS).orElseThrow()
        assertEquals(Topics.state(ACCOUNT, ResourceType.AUDIO), publish.topic.toString())
        assertEquals("""{"holder":"$NODE"}""", String(publish.payloadAsBytes))
    }

    private suspend fun publishUntil(
        relay: Mqtt3BlockingClient,
        payload: String,
        done: () -> Boolean,
    ) {
        withTimeout(TIMEOUT_SECONDS * 1000) {
            while (!done()) {
                relay.publishWith()
                    .topic(COMMANDS_TOPIC)
                    .qos(MqttQos.AT_LEAST_ONCE)
                    .payload(payload.toByteArray())
                    .send()
                delay(100)
            }
        }
    }

    private suspend fun connectTransport(): MqttTransport =
        HiveMqttTransport.connect(config, NODE).also { transport ->
            closeables += { runBlocking { transport.close() } }
        }

    private fun connectRelayClient(identifier: String = "relay-test"): Mqtt3BlockingClient {
        val client = Mqtt3Client.builder()
            .identifier(identifier)
            .serverHost(config.host)
            .serverPort(config.port)
            .webSocketConfig(MqttWebSocketConfig.builder().serverPath(config.webSocketPath).build())
            .buildBlocking()
        client.connect()
        closeables += { client.disconnect() }
        return client
    }

    private class RecordingGateway : BluetoothClassicGateway {
        // Written from the listener coroutine's thread, read from the test's.
        val connectCalls = CopyOnWriteArrayList<String>()
        val disconnectCalls = CopyOnWriteArrayList<String>()

        override suspend fun connect(deviceAddress: String) {
            connectCalls += deviceAddress
        }

        override suspend fun disconnect(deviceAddress: String) {
            disconnectCalls += deviceAddress
        }
    }

    private companion object {
        const val HOST = "127.0.0.1"
        const val ACCOUNT = "acct-1"
        const val NODE = "pixel-10-pro"
        const val HEADSET = "AA:BB:CC:DD:EE:FF"
        const val TIMEOUT_SECONDS = 15L

        val EVENTS_TOPIC = Topics.events(ACCOUNT, NODE, ResourceType.AUDIO)
        val COMMANDS_TOPIC = Topics.commands(ACCOUNT, NODE, ResourceType.AUDIO)

        val MANIFEST = NodeManifest(
            nodeId = NODE,
            platform = Platform.ANDROID,
            displayName = "Pixel 10 Pro",
            adapterVersion = "0.0.0",
            supportedEventKinds = listOf(EventKind.CALL, EventKind.VOIP, EventKind.MEDIA),
            supportedResourceTypes = listOf(ResourceType.AUDIO),
        )

        fun freePort(): Int = ServerSocket(0).use { it.localPort }
    }
}
