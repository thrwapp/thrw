@file:OptIn(ExperimentalCoroutinesApi::class)

package com.thrw.adapter.android

import com.thrw.adapter.android.bluetooth.BluetoothClassicGateway
import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.heartbeat.HeartbeatRunner
import com.thrw.adapter.android.registration.RegistrationRunner
import com.thrw.adapter.android.mqtt.MqttTransport
import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.protocol.Platform
import com.thrw.adapter.android.protocol.ProtocolJson
import com.thrw.adapter.android.triggers.CallStateSource
import com.thrw.adapter.android.triggers.MediaSessionEvent
import com.thrw.adapter.android.triggers.MediaSessionSource
import com.thrw.adapter.android.triggers.MediaTriggerMonitor
import com.thrw.adapter.android.triggers.CallTriggerMonitor
import com.thrw.adapter.android.triggers.NotificationEvent
import com.thrw.adapter.android.triggers.NotificationSource
import com.thrw.adapter.android.triggers.PhoneCallState
import com.thrw.adapter.android.triggers.PostedNotification
import com.thrw.adapter.android.triggers.VoipTriggerMonitor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

private data class RuntimePublished(val topic: String, val payload: String, val qos: Int)

/** Same fakes as `AndroidNodeTest.kt` - see that file's kdoc for why. */
private class RuntimeFakeMqttTransport : MqttTransport {
    val published = mutableListOf<RuntimePublished>()
    val commands = Channel<String>(Channel.UNLIMITED)
    val subscriptions = mutableListOf<Pair<String, Int>>()

    override suspend fun publish(topic: String, payload: String, qos: Int, retained: Boolean) {
        published += RuntimePublished(topic, payload, qos)
    }

    override fun subscribe(topic: String, qos: Int): Flow<String> {
        subscriptions += topic to qos
        return commands.consumeAsFlow()
    }

    /** Set by the node under test; fired by [simulateReconnect]. */
    private var reconnectHandler: (() -> Unit)? = null

    override fun onReconnected(handler: () -> Unit) {
        reconnectHandler = handler
    }

    /** Stands in for the transport re-establishing a dropped connection. */
    fun simulateReconnect() = reconnectHandler?.invoke()

    override suspend fun close() = Unit
}

private class RuntimeRecordingGateway : BluetoothClassicGateway {
    override suspend fun connect(deviceAddress: String) = Unit

    override suspend fun disconnect(deviceAddress: String) = Unit
}

private const val ACCOUNT = "acct-1"
private const val NODE = "node-1"
private const val HEADSET = "AA:BB:CC:DD:EE:FF"
private const val EVENTS_TOPIC = "thrw/$ACCOUNT/nodes/$NODE/events"
private const val COMMANDS_TOPIC = "thrw/$ACCOUNT/commands/$NODE"
private const val HEARTBEAT_TOPIC = "thrw/$ACCOUNT/nodes/$NODE/heartbeat"

private val MANIFEST = NodeManifest(
    nodeId = NODE,
    platform = Platform.ANDROID,
    displayName = "Test Device",
    adapterVersion = "0.1.0",
    supportedEventKinds = listOf(EventKind.CALL, EventKind.VOIP),
)

/**
 * Tests [NodeRuntime] - the composition root's testable half (#96's
 * acceptance criterion 4). [AdapterForegroundService], the untestable
 * half that constructs real android.bluetooth/android.telephony/
 * NotificationListenerService-backed dependencies, is exercised by none of
 * this - see docs/handoffs/96.md for what is and isn't covered.
 */
class NodeRuntimeTest {
    @Test
    fun `start registers the given manifest on the node's events topic`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(emptyCallStateSource(), node),
            voipTriggerMonitor = VoipTriggerMonitor(emptyNotificationSource(), node),
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = noHeartbeat(),
            registrationRunner = noReregistration(),
        )

        runtime.start(this, MANIFEST)
        transport.commands.close()
        advanceUntilIdle()

        val registration = transport.published.single { it.topic == EVENTS_TOPIC }
        val body = ProtocolJson.parseToJsonElement(registration.payload) as JsonObject
        assertEquals("register", body.getValue("kind").jsonPrimitive.content)
        assertEquals(NODE, (body.getValue("manifest") as JsonObject).getValue("nodeId").jsonPrimitive.content)
    }

    @Test
    fun `start subscribes to the node's own commands topic at QoS 1`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(emptyCallStateSource(), node),
            voipTriggerMonitor = VoipTriggerMonitor(emptyNotificationSource(), node),
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = noHeartbeat(),
            registrationRunner = noReregistration(),
        )

        runtime.start(this, MANIFEST)
        transport.commands.close()
        advanceUntilIdle()

        assertEquals(listOf(COMMANDS_TOPIC to 1), transport.subscriptions)
    }

    @Test
    fun `start wires the call trigger monitor through to the relay`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        val callSource = object : CallStateSource {
            override fun callStates(): Flow<PhoneCallState> =
                listOf(PhoneCallState.OFFHOOK, PhoneCallState.IDLE).asFlow()
        }
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(callSource, node),
            voipTriggerMonitor = VoipTriggerMonitor(emptyNotificationSource(), node),
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = noHeartbeat(),
            registrationRunner = noReregistration(),
        )

        runtime.start(this, MANIFEST)
        transport.commands.close()
        advanceUntilIdle()

        assertEquals(
            listOf("""{"type":"call","priority":0}""", """{"kind":"event_end","type":"call"}"""),
            transport.published.filter { it.topic == EVENTS_TOPIC }.map { it.payload }.drop(1),
        )
    }

    @Test
    fun `start wires the VoIP trigger monitor through to the relay`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        val call = PostedNotification(
            key = "zoom|1",
            packageName = "us.zoom.videomeetings",
            category = "call",
            flags = 0x00000002 or 0x00000040,
        )
        val notificationSource = object : NotificationSource {
            override fun notifications(): Flow<NotificationEvent> =
                listOf(NotificationEvent.Posted(call), NotificationEvent.Removed(call.key)).asFlow()
        }
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(emptyCallStateSource(), node),
            voipTriggerMonitor = VoipTriggerMonitor(notificationSource, node),
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = noHeartbeat(),
            registrationRunner = noReregistration(),
        )

        runtime.start(this, MANIFEST)
        transport.commands.close()
        advanceUntilIdle()

        assertEquals(
            listOf("""{"type":"voip","priority":0}""", """{"kind":"event_end","type":"voip"}"""),
            transport.published.filter { it.topic == EVENTS_TOPIC }.map { it.payload }.drop(1),
        )
    }

    @Test
    fun `all four launched coroutines run independently of each other`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        val callSource = object : CallStateSource {
            override fun callStates(): Flow<PhoneCallState> = listOf(PhoneCallState.OFFHOOK).asFlow()
        }
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(callSource, node),
            voipTriggerMonitor = VoipTriggerMonitor(emptyNotificationSource(), node),
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = noHeartbeat(),
            registrationRunner = noReregistration(),
        )

        // The commands subscription (from listenForCommands) never
        // completes on its own - only closing the channel lets it finish.
        // If it were launched sequentially before the other three (rather
        // than each in its own coroutine), this call would hang forever
        // and the test would time out.
        runtime.start(this, MANIFEST)
        transport.commands.close()
        advanceUntilIdle()

        assertTrue(transport.published.any { it.payload.contains("\"call\"") })
    }

    /**
     * #142: the relay only subscribes to a node's heartbeat topic once it
     * has seen that node register (`relay-service.ts`'s `handleEvent` ->
     * `trackHeartbeat`), so a beat published before registration goes to a
     * topic nothing is listening to. This ordering is a correctness
     * property, not a test convenience.
     */
    @Test
    fun `the first heartbeat is not published before registration`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(emptyCallStateSource(), node),
            voipTriggerMonitor = VoipTriggerMonitor(emptyNotificationSource(), node),
            // Beats once and returns, so advanceUntilIdle() terminates.
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = { node.publishHeartbeat() },
            registrationRunner = noReregistration(),
        )

        runtime.start(this, MANIFEST)
        transport.commands.close()
        advanceUntilIdle()

        val topics = transport.published.map { it.topic }
        assertTrue(topics.contains(HEARTBEAT_TOPIC), "expected a heartbeat to be published")
        assertTrue(
            topics.indexOf(EVENTS_TOPIC) < topics.indexOf(HEARTBEAT_TOPIC),
            "the registration must be published before the first heartbeat, got $topics",
        )
    }

    /**
     * #182. Reconnecting restores the connection, not the relay's memory
     * of this node - the relay learns of a node only from a registration
     * and holds it in memory. A node that reconnects without registering
     * is connected but invisible, and waiting out the 2-minute periodic
     * timer leaves a window where the headset cannot be arbitrated.
     */
    @Test
    fun `reconnecting re-registers the node`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(emptyCallStateSource(), node),
            voipTriggerMonitor = VoipTriggerMonitor(emptyNotificationSource(), node),
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = noHeartbeat(),
            registrationRunner = noReregistration(),
        )

        runtime.start(this, MANIFEST)
        advanceUntilIdle()
        val beforeReconnect = transport.published.count { it.topic == EVENTS_TOPIC }

        transport.simulateReconnect()
        transport.commands.close()
        advanceUntilIdle()

        assertEquals(
            beforeReconnect + 1,
            transport.published.count { it.topic == EVENTS_TOPIC },
            "a reconnect must produce a fresh registration",
        )
    }

    @Test
    fun `the heartbeat runner is actually started by start`() = runTest {
        val transport = RuntimeFakeMqttTransport()
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(RuntimeRecordingGateway()))
        var beats = 0
        val runtime = NodeRuntime(
            node = node,
            callTriggerMonitor = CallTriggerMonitor(emptyCallStateSource(), node),
            voipTriggerMonitor = VoipTriggerMonitor(emptyNotificationSource(), node),
            mediaTriggerMonitor = MediaTriggerMonitor(emptyMediaSessionSource(), node),
            heartbeatRunner = { beats++ },
            registrationRunner = noReregistration(),
        )

        runtime.start(this, MANIFEST)
        transport.commands.close()
        advanceUntilIdle()

        assertEquals(1, beats)
    }

    /**
     * A runner that returns immediately. `HeartbeatPublisher.run()` never
     * returns on its own, so using the real one here would leave
     * `advanceUntilIdle()` with a `delay` always scheduled and hang the
     * test forever - see [com.thrw.adapter.android.heartbeat.HeartbeatRunner].
     */
    private fun noHeartbeat() = HeartbeatRunner {}

    /**
     * Same reason as [noHeartbeat]: the real `RegistrationPublisher`
     * loops on `delay` forever, so `advanceUntilIdle()` under `runTest`'s
     * virtual clock would never see the scheduler go idle.
     */
    private fun noReregistration() = RegistrationRunner { }

    private fun emptyMediaSessionSource() = object : MediaSessionSource {
        override fun sessions(): Flow<MediaSessionEvent> = emptyList<MediaSessionEvent>().asFlow()
    }

    private fun emptyCallStateSource() = object : CallStateSource {
        override fun callStates(): Flow<PhoneCallState> = emptyList<PhoneCallState>().asFlow()
    }

    private fun emptyNotificationSource() = object : NotificationSource {
        override fun notifications(): Flow<NotificationEvent> = emptyList<NotificationEvent>().asFlow()
    }
}
