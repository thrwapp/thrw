package com.thrw.adapter.android

import com.thrw.adapter.android.bluetooth.BluetoothClassicGateway
import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.bluetooth.BluetoothConnectionState
import com.thrw.adapter.android.mqtt.MqttTransport
import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.protocol.Platform
import com.thrw.adapter.android.protocol.ProtocolJson
import com.thrw.adapter.android.triggers.CALL_STYLE_TEMPLATE
import com.thrw.adapter.android.triggers.CATEGORY_CALL
import com.thrw.adapter.android.triggers.CallStateSource
import com.thrw.adapter.android.triggers.CallTriggerMonitor
import com.thrw.adapter.android.triggers.CallType
import com.thrw.adapter.android.triggers.NotificationEvent
import com.thrw.adapter.android.triggers.NotificationFlags
import com.thrw.adapter.android.triggers.NotificationSource
import com.thrw.adapter.android.triggers.PhoneCallState
import com.thrw.adapter.android.triggers.PostedNotification
import com.thrw.adapter.android.triggers.SelfCooldown
import com.thrw.adapter.android.triggers.UNRANKED_PRIORITY
import com.thrw.adapter.android.triggers.VoipTriggerMonitor
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

private data class Published(
    val topic: String,
    val payload: String,
    val qos: Int,
    val retained: Boolean,
)

/**
 * Fakes the [MqttTransport] seam. The end-to-end behaviour against a real
 * broker (that these topics/QoS are actually accepted and delivered) is
 * covered separately by `mqtt/HiveMqttTransportTest`, against an embedded
 * Moquette broker.
 */
private class FakeMqttTransport : MqttTransport {
    val published = mutableListOf<Published>()
    val commands = Channel<String>(Channel.UNLIMITED)
    val subscriptions = mutableListOf<Pair<String, Int>>()
    var closed = false

    override suspend fun publish(topic: String, payload: String, qos: Int, retained: Boolean) {
        published += Published(topic, payload, qos, retained)
    }

    override fun subscribe(topic: String, qos: Int): Flow<String> {
        subscriptions += topic to qos
        return commands.consumeAsFlow()
    }

    override suspend fun close() {
        closed = true
    }
}

private class RecordingGateway : BluetoothClassicGateway {
    val connectCalls = mutableListOf<String>()
    val disconnectCalls = mutableListOf<String>()

    override suspend fun connect(deviceAddress: String) {
        connectCalls += deviceAddress
    }

    override suspend fun disconnect(deviceAddress: String) {
        disconnectCalls += deviceAddress
    }
}

private const val ACCOUNT = "acct-1"
private const val NODE = "pixel-10-pro"
private const val HEADSET = "AA:BB:CC:DD:EE:FF"
private const val EVENTS_TOPIC = "thrw/$ACCOUNT/nodes/$NODE/events"
private const val COMMANDS_TOPIC = "thrw/$ACCOUNT/commands/$NODE"
private const val HEARTBEAT_TOPIC = "thrw/$ACCOUNT/nodes/$NODE/heartbeat"

private val MANIFEST = NodeManifest(
    nodeId = NODE,
    platform = Platform.ANDROID,
    displayName = "Pixel 10 Pro",
    adapterVersion = "0.0.0",
    supportedEventKinds = listOf(EventKind.CALL, EventKind.VOIP, EventKind.MEDIA, EventKind.MANUAL_CLAIM),
)

private class Fixture {
    val transport = FakeMqttTransport()
    val gateway = RecordingGateway()
    val bluetooth = BluetoothConnectionManager(gateway)
    val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, bluetooth)
}

class AndroidNodeTest {
    @Test
    fun `register publishes the manifest on the node's events topic at QoS 1`() = runTest {
        val f = Fixture()

        f.node.register(MANIFEST)

        val sent = f.transport.published.single()
        assertEquals(EVENTS_TOPIC, sent.topic)
        assertEquals(1, sent.qos)
        assertFalse(sent.retained)

        val body = ProtocolJson.parseToJsonElement(sent.payload) as JsonObject
        assertEquals("register", body.getValue("kind").jsonPrimitive.content)
        val manifest = body.getValue("manifest") as JsonObject
        assertEquals(NODE, manifest.getValue("nodeId").jsonPrimitive.content)
        assertEquals("android", manifest.getValue("platform").jsonPrimitive.content)
        assertEquals("Pixel 10 Pro", manifest.getValue("displayName").jsonPrimitive.content)
    }

    @Test
    fun `emitEvent publishes type and priority to the events topic at QoS 1`() = runTest {
        val f = Fixture()

        f.node.emitEvent(EventKind.CALL, 1)

        val sent = f.transport.published.single()
        assertEquals(EVENTS_TOPIC, sent.topic)
        assertEquals(1, sent.qos)
        assertFalse(sent.retained)
        assertEquals("""{"type":"call","priority":1}""", sent.payload)
    }

    @Test
    fun `every EventKind emits its protocol wire spelling`() = runTest {
        val f = Fixture()

        EventKind.entries.forEachIndexed { index, kind -> f.node.emitEvent(kind, index) }

        assertEquals(
            listOf(
                """{"type":"call","priority":0}""",
                """{"type":"manual_claim","priority":1}""",
                """{"type":"voip","priority":2}""",
                """{"type":"media","priority":3}""",
            ),
            f.transport.published.map { it.payload },
        )
    }

    @Test
    fun `endEvent publishes an event_end envelope on the events topic at QoS 1`() = runTest {
        val f = Fixture()

        f.node.endEvent(EventKind.CALL)

        val sent = f.transport.published.single()
        assertEquals(EVENTS_TOPIC, sent.topic)
        assertEquals(1, sent.qos)
        assertFalse(sent.retained)
        assertEquals("""{"kind":"event_end","type":"call"}""", sent.payload)
    }

    @Test
    fun `publishHeartbeat publishes an empty payload on the heartbeat topic at QoS 0`() = runTest {
        val f = Fixture()

        f.node.publishHeartbeat()

        val sent = f.transport.published.single()
        assertEquals(HEARTBEAT_TOPIC, sent.topic)
        assertEquals(0, sent.qos)
        assertFalse(sent.retained)
        // Empty on purpose - arrival is the whole signal, and
        // relay-core's subscribeHeartbeat ignores the body (#142).
        assertEquals("", sent.payload)
    }

    @Test
    fun `the heartbeat does not ride the events topic`() = runTest {
        val f = Fixture()

        f.node.publishHeartbeat()

        assertNotEquals(EVENTS_TOPIC, f.transport.published.single().topic)
    }

    @Test
    fun `a phone call start and end reach the relay as a start then an event_end`() = runTest {
        val f = Fixture()
        val monitor = CallTriggerMonitor(
            object : CallStateSource {
                override fun callStates(): Flow<PhoneCallState> =
                    listOf(PhoneCallState.RINGING, PhoneCallState.OFFHOOK, PhoneCallState.IDLE).asFlow()
            },
            f.node,
        )

        monitor.run()

        assertEquals(
            listOf(
                """{"type":"call","priority":$UNRANKED_PRIORITY}""",
                """{"kind":"event_end","type":"call"}""",
            ),
            f.transport.published.map { it.payload },
        )
        assertTrue(f.transport.published.all { it.topic == EVENTS_TOPIC && it.qos == 1 })
    }

    @Test
    fun `a VoIP session start and end reach the relay as a start then an event_end`() = runTest {
        val f = Fixture()
        val ongoingZoomCall = PostedNotification(
            key = "zoom|1",
            packageName = "us.zoom.videomeetings",
            category = CATEGORY_CALL,
            flags = NotificationFlags.FOREGROUND_SERVICE or NotificationFlags.ONGOING_EVENT,
            template = CALL_STYLE_TEMPLATE,
            callType = CallType.ONGOING,
        )
        val monitor = VoipTriggerMonitor(
            object : NotificationSource {
                override fun notifications(): Flow<NotificationEvent> =
                    listOf(
                        NotificationEvent.Posted(ongoingZoomCall),
                        NotificationEvent.Removed(ongoingZoomCall.key),
                    ).asFlow()
            },
            f.node,
        )

        monitor.run()

        assertEquals(
            listOf(
                """{"type":"voip","priority":$UNRANKED_PRIORITY}""",
                """{"kind":"event_end","type":"voip"}""",
            ),
            f.transport.published.map { it.payload },
        )
    }

    @Test
    fun `onClaim connects the headset through the Bluetooth connection manager`() = runTest {
        val f = Fixture()

        f.node.onClaim()

        assertEquals(listOf(HEADSET), f.gateway.connectCalls)
        assertEquals(BluetoothConnectionState.CONNECTED, f.bluetooth.connectionState(HEADSET))
    }

    @Test
    fun `onRelease disconnects the headset through the Bluetooth connection manager`() = runTest {
        val f = Fixture()
        f.node.onClaim()

        f.node.onRelease()

        assertEquals(listOf(HEADSET), f.gateway.disconnectCalls)
        assertEquals(BluetoothConnectionState.DISCONNECTED, f.bluetooth.connectionState(HEADSET))
    }

    @Test
    fun `claim and release publish nothing - the relay already knows it asked`() = runTest {
        val f = Fixture()

        f.node.onClaim()
        f.node.onRelease()

        assertTrue(f.transport.published.isEmpty())
    }

    @Test
    fun `relay commands on the commands topic drive claim and release`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"claim"}""")
        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf(COMMANDS_TOPIC to 1), f.transport.subscriptions)
        assertEquals(listOf(HEADSET), f.gateway.connectCalls)
        assertEquals(listOf(HEADSET), f.gateway.disconnectCalls)
    }

    /**
     * #161: a headset that is off, out of range or busy makes the
     * gateway throw. Before this, that propagated out of
     * listenForCommands and killed the whole adapter process on real
     * hardware. It must be logged and skipped, exactly like an
     * unparseable payload.
     */
    /**
     * #167 / ADR 0010 point 1: after thrw claims, the audio routing
     * change it caused must not come straight back as a new trigger.
     */
    @Test
    fun `a trigger reported inside the self-cooldown window is suppressed`() = runTest {
        var millis = 0L
        val transport = FakeMqttTransport()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(RecordingGateway()),
            selfCooldown = SelfCooldown(windowMs = 3_000) { millis },
        )

        node.onClaim()
        node.emitEvent(EventKind.MEDIA, 0)

        assertTrue(transport.published.isEmpty(), "the self-inflicted trigger must not reach the relay")
    }

    @Test
    fun `the same trigger is reported once the window has elapsed`() = runTest {
        var millis = 0L
        val transport = FakeMqttTransport()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(RecordingGateway()),
            selfCooldown = SelfCooldown(windowMs = 3_000) { millis },
        )

        node.onClaim()
        millis = 3_000
        node.emitEvent(EventKind.MEDIA, 0)

        assertEquals(1, transport.published.size)
    }

    /**
     * Criterion 2: the cooldown stops thrw talking to itself, it must not
     * make the node deaf to the relay. A CLAIM arriving inside the window
     * is still honoured.
     */
    @Test
    fun `a relay command inside the window is still honoured`() = runTest {
        var millis = 0L
        val transport = FakeMqttTransport()
        val gateway = RecordingGateway()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(gateway),
            selfCooldown = SelfCooldown(windowMs = 3_000) { millis },
        )

        node.onRelease()
        transport.commands.send("""{"type":"claim"}""")
        transport.commands.close()
        node.listenForCommands()

        assertEquals(listOf(HEADSET), gateway.connectCalls, "a relay CLAIM must still connect during cooldown")
    }

    @Test
    fun `a failing claim does not tear down the commands subscription`() = runTest {
        val transport = FakeMqttTransport()
        val gateway = object : BluetoothClassicGateway {
            var connectAttempts = 0
            override suspend fun connect(deviceAddress: String) {
                connectAttempts++
                throw java.io.IOException("read failed, socket might closed or timeout, read ret: -1")
            }
            override suspend fun disconnect(deviceAddress: String) = Unit
        }
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(gateway))

        transport.commands.send("""{"type":"claim"}""")
        // The second claim only arrives if the first didn't end the flow.
        transport.commands.send("""{"type":"claim"}""")
        transport.commands.close()

        node.listenForCommands()

        assertEquals(2, gateway.connectAttempts, "the subscription must survive a failed claim")
    }

    @Test
    fun `an unparseable command is skipped without dropping the subscription`() = runTest {
        val f = Fixture()
        f.transport.commands.send("not json")
        f.transport.commands.send("""{"type":"teleport"}""")
        f.transport.commands.send("""{"type":"claim"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf(HEADSET), f.gateway.connectCalls)
    }
}
