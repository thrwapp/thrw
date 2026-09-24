package com.thrw.adapter.android

import kotlinx.coroutines.awaitCancellation
import com.thrw.adapter.android.audio.HandoverAudioGate
import com.thrw.adapter.android.audio.NoOpHandoverAudioGate
import com.thrw.adapter.android.bluetooth.BluetoothClassicGateway
import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.bluetooth.BluetoothConnectionState
import com.thrw.adapter.android.mqtt.MqttTransport
import com.thrw.adapter.android.protocol.COMMAND_OUTCOME_KIND
import com.thrw.adapter.android.protocol.CommandOutcomePayload
import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.ResourceType
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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
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

    /**
     * #234. A second channel, because a `Channel.consumeAsFlow()` can be
     * consumed exactly once - handing the same one to both the commands
     * and state subscriptions makes whichever collects second fail, and
     * splits elements between them until it does.
     */
    val state = Channel<String>(Channel.UNLIMITED)
    val subscriptions = mutableListOf<Pair<String, Int>>()
    var closed = false

    /**
     * #234. Defaults to true, matching [MqttTransport]'s own default so
     * every existing test is unaffected; set false to check that a node
     * stops presenting relay state it can no longer verify.
     */
    var connected = true

    /**
     * #206. Makes every publish throw, so a test can prove a lost
     * outcome report does not take the command loop down with it.
     */
    var failPublishes = false

    override suspend fun publish(topic: String, payload: String, qos: Int, retained: Boolean) {
        if (failPublishes) throw IllegalStateException("simulated publish failure")
        published += Published(topic, payload, qos, retained)
    }

    /**
     * Routed by topic shape rather than exact string, so the fixture
     * does not need to know which account/node a given test built its
     * topics from.
     */
    override fun subscribe(topic: String, qos: Int): Flow<String> {
        subscriptions += topic to qos
        return if ("/state/" in topic) state.consumeAsFlow() else commands.consumeAsFlow()
    }

    override fun isConnected(): Boolean = connected

    override suspend fun close() {
        closed = true
    }
}

private class RecordingGateway(private var failConnectTimes: Int = 0) : BluetoothClassicGateway {
    val connectCalls = mutableListOf<String>()
    val disconnectCalls = mutableListOf<String>()

    /** #254 - drives the `timed_out` path, so restore-on-timeout is reachable. */
    var hangNextConnect = false

    override suspend fun connect(deviceAddress: String) {
        if (hangNextConnect) {
            hangNextConnect = false
            connectCalls += deviceAddress
            awaitCancellation()
        }
        connectCalls += deviceAddress
        // #210: a headset that is off, out of range or busy makes the
        // real gateway throw (#161). The call is still recorded, so a
        // test can tell "was attempted and failed" from "was discarded
        // and never attempted" - which is the whole distinction the
        // retry test turns on.
        if (failConnectTimes > 0) {
            failConnectTimes--
            error("simulated connect failure")
        }
    }

    override suspend fun disconnect(deviceAddress: String) {
        disconnectCalls += deviceAddress
    }
}

private const val ACCOUNT = "acct-1"
private const val NODE = "pixel-10-pro"
private const val HEADSET = "AA:BB:CC:DD:EE:FF"
private const val EVENTS_TOPIC = "thrw/$ACCOUNT/nodes/$NODE/audio/events"
private const val COMMANDS_TOPIC = "thrw/$ACCOUNT/commands/$NODE/audio"
private const val HEARTBEAT_TOPIC = "thrw/$ACCOUNT/nodes/$NODE/heartbeat"
private const val STATE_TOPIC = "thrw/$ACCOUNT/state/audio"

private val MANIFEST = NodeManifest(
    nodeId = NODE,
    platform = Platform.ANDROID,
    displayName = "Pixel 10 Pro",
    adapterVersion = "0.0.0",
    supportedEventKinds = listOf(EventKind.CALL, EventKind.VOIP, EventKind.MEDIA, EventKind.MANUAL_CLAIM),
    supportedResourceTypes = listOf(ResourceType.AUDIO),
)

/** #254. Records the order of gate calls, which is the whole contract. */
private class RecordingAudioGate : HandoverAudioGate {
    val calls = mutableListOf<String>()
    override suspend fun silence() { calls += "silence" }
    override suspend fun restore() { calls += "restore" }
}

private class Fixture(
    failConnectTimes: Int = 0,
    hangConnect: Boolean = false,
    audioGate: HandoverAudioGate = NoOpHandoverAudioGate,
) {
    val transport = FakeMqttTransport()
    val gateway = RecordingGateway(failConnectTimes).also { it.hangNextConnect = hangConnect }
    val bluetooth = BluetoothConnectionManager(gateway)
    val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, bluetooth, audioGate = audioGate)
}

class AndroidNodeTest {
    /**
     * #183, reproduced. A call that ends *inside* the self-cooldown
     * window strands the relay with a `call` that never ends.
     *
     * 1. The call starts and is published; `activeEvents` gains `call`.
     * 2. The relay claims, and `onClaim` arms the cooldown.
     * 3. The call ends within those three seconds, so `endEvent` returns
     *    early - before removing from `activeEvents`.
     * 4. `CallTriggerMonitor` has already cleared its own flag, so it
     *    never retries.
     *
     * The relay is left holding the highest-priority signal in the
     * system forever, and #178's periodic registration *perpetuates* it
     * by reporting `activeEvents: ["call"]` - the reconciliation that
     * should repair this instead keeps it alive.
     */
    @Test
    fun `a trigger ended inside the cooldown is not left reported as active`() = runTest {
        var millis = 0L
        val transport = FakeMqttTransport()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(RecordingGateway()),
            selfCooldown = SelfCooldown(windowMs = 3_000) { millis },
        )

        node.emitEvent(EventKind.CALL, 0)
        node.onClaim()
        node.endEvent(EventKind.CALL)

        node.register(MANIFEST)
        assertEquals(
            emptyList<String>(),
            activeEventsOf(transport.published.last().payload),
            "a suppressed end must not leave the trigger reported as active - #178 would keep it alive forever",
        )
    }


    /**
     * #212. The cooldown exists so thrw ignores its **own** side effects
     * (#167). A manual claim is the user acting, not an echo, and ADR
     * 0010 says direct user action always wins - so it must go out even
     * inside the window. Without this the override silently does nothing
     * for three seconds after any switch, which is exactly when a user
     * reaches for it.
     */
    @Test
    fun `a manual claim is published even inside the self-cooldown`() = runTest {
        val transport = FakeMqttTransport()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(RecordingGateway()),
            selfCooldown = SelfCooldown(windowMs = 3_000) { 0L },
        )

        node.onClaim()
        node.emitEvent(EventKind.MANUAL_CLAIM, 0)

        assertTrue(
            transport.published.any { it.payload.contains("manual_claim") },
            "a manual claim must not be suppressed by the cooldown",
        )
    }

    @Test
    fun `releasing a manual claim is also published inside the cooldown`() = runTest {
        val transport = FakeMqttTransport()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(RecordingGateway()),
            selfCooldown = SelfCooldown(windowMs = 3_000) { 0L },
        )

        node.onClaim()
        node.endEvent(EventKind.MANUAL_CLAIM)

        assertTrue(transport.published.any { it.payload.contains("manual_claim") })
    }

    /**
     * `voip` and `media` remain suppressed. Both derive from audio
     * state, so both can legitimately be an echo of thrw's own action -
     * suppressing them is the whole point of #167 and must not regress.
     * `media` is exactly what chattered in #251.
     *
     * `call` used to be in this list. It moved to the exempt set when
     * #251 lengthened the window to 6s - see the test below for why.
     */
    @Test
    fun `audio-derived triggers are still suppressed by the cooldown`() = runTest {
        for (kind in listOf(EventKind.MEDIA, EventKind.VOIP)) {
            val transport = FakeMqttTransport()
            val node = AndroidNode(
                ACCOUNT, NODE, HEADSET, transport,
                BluetoothConnectionManager(RecordingGateway()),
                selfCooldown = SelfCooldown(windowMs = 6_000) { 0L },
            )

            node.onClaim()
            node.emitEvent(kind, 0)

            assertTrue(transport.published.isEmpty(), "$kind must still be suppressed")
        }
    }

    /**
     * #251. At a 3s window, a call suppressed by the cooldown was a
     * narrow enough gap to live with. At 6s it is not - and a call is
     * the signal this product can least afford to miss, being first in
     * `PRIORITY_ORDER`.
     *
     * Exempting it is safe on principle rather than merely convenient:
     * the cooldown exists because connecting the headset changes audio
     * routing, and Android's call signal is `TelephonyCallback`
     * (telephony state), not a route observation. A real call cannot be
     * an echo of our own action.
     */
    @Test
    fun `a call is not suppressed by the cooldown`() = runTest {
        val transport = FakeMqttTransport()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(RecordingGateway()),
            selfCooldown = SelfCooldown(windowMs = 6_000) { 0L },
        )

        node.onClaim()
        node.emitEvent(EventKind.CALL, 0)

        assertEquals(1, transport.published.size, "a call must reach the relay even mid-cooldown")
    }

    private fun activeEventsOf(payload: String): List<String> =
        ((ProtocolJson.parseToJsonElement(payload) as JsonObject)["activeEvents"] as? JsonArray)
            ?.map { it.jsonPrimitive.content } ?: emptyList()

    /**
     * #178. The point of the whole mechanism: a periodic registration has
     * to tell the relay what is playing *now*, or a relay that lost its
     * state stays blind to a node that is mid-playback.
     */
    @Test
    fun `register reports the triggers this node has active`() = runTest {
        val f = Fixture()

        f.node.emitEvent(EventKind.MEDIA, 0)
        f.node.register(MANIFEST)

        assertEquals(listOf("media"), activeEventsOf(f.transport.published.last().payload))
    }

    @Test
    fun `a trigger that ended is no longer reported`() = runTest {
        val f = Fixture()

        f.node.emitEvent(EventKind.MEDIA, 0)
        f.node.endEvent(EventKind.MEDIA)
        f.node.register(MANIFEST)

        assertEquals(emptyList<String>(), activeEventsOf(f.transport.published.last().payload))
    }

    /**
     * The subtle one. [SelfCooldown] exists so thrw doesn't react to its
     * own claim/release (#167) - a suppressed trigger was never told to
     * the relay at all. Recording it here would smuggle it out on the
     * next periodic registration and undo the suppression entirely.
     */
    @Test
    fun `a trigger suppressed by the self-cooldown is not reported`() = runTest {
        val transport = FakeMqttTransport()
        val node = AndroidNode(
            ACCOUNT, NODE, HEADSET, transport,
            BluetoothConnectionManager(RecordingGateway()),
            selfCooldown = SelfCooldown(windowMs = 3_000) { 0L },
        )

        node.onClaim()
        node.emitEvent(EventKind.MEDIA, 0)
        node.register(MANIFEST)

        assertEquals(
            emptyList<String>(),
            activeEventsOf(transport.published.last().payload),
            "a suppressed trigger must not leak out via registration",
        )
    }

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

    // ADR 0022 / #254 - silencing audio across the handover window.

    /**
     * On release, silence and **do not** restore. The user has moved to
     * another device; continuing to play here is never what they wanted,
     * and it mirrors what the platform itself does on
     * AUDIO_BECOMING_NOISY when headphones are unplugged.
     */
    @Test
    fun `a release silences and does not restore`() = runTest {
        val gate = RecordingAudioGate()
        val f = Fixture(audioGate = gate)
        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf("silence"), gate.calls)
    }

    /**
     * On claim, silence then restore once the outcome is known - brief
     * silence beats ~5s through the phone speaker, and nothing is lost.
     */
    @Test
    fun `a claim silences and then restores`() = runTest {
        val gate = RecordingAudioGate()
        val f = Fixture(audioGate = gate)
        f.transport.commands.send("""{"type":"claim"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf("silence", "restore"), gate.calls)
    }

    /**
     * ADR 0022 requires restoring on *every* terminal outcome. A user
     * left silenced because a claim failed would be a worse bug than the
     * audio leak this prevents - and a failed claim is exactly when the
     * headset did not arrive, so the audio has nowhere to go but here.
     */
    @Test
    fun `a failed claim still restores`() = runTest {
        val gate = RecordingAudioGate()
        val f = Fixture(failConnectTimes = 1, audioGate = gate)
        f.transport.commands.send("""{"type":"claim"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf("silence", "restore"), gate.calls)
    }

    /** The other terminal outcome: #244's bound firing. Same rule. */
    @Test
    fun `a timed-out claim still restores`() = runTest {
        val gate = RecordingAudioGate()
        val f = Fixture(hangConnect = true, audioGate = gate)
        f.transport.commands.send("""{"type":"claim"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf("silence", "restore"), gate.calls)
    }

    /**
     * A command the sequence gate discards never happened, so it must
     * not touch audio at all. Silencing for a superseded command would
     * pause the user's media for a claim that was never executed.
     */
    @Test
    fun `a superseded command does not touch audio`() = runTest {
        val gate = RecordingAudioGate()
        val f = Fixture(audioGate = gate)
        f.transport.commands.send("""{"type":"claim","seq":2,"epoch":"e1"}""")
        f.transport.commands.send("""{"type":"release","seq":1,"epoch":"e1"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        // The claim's pair only - the stale release contributes nothing.
        assertEquals(listOf("silence", "restore"), gate.calls)
    }

    /**
     * Without a gate the node behaves exactly as it did before ADR 0022.
     * Leaking audio as it always has is a better failure than refusing
     * to hand over at all.
     */
    @Test
    fun `without a gate the node still hands over`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"claim"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf(HEADSET), f.gateway.connectCalls)
    }

    // ADR 0019 / #206 stage 2 - command outcomes.

    /**
     * Reported for **every** command, not only failures. A success rate
     * needs its denominator, or "reliability" stays inferred from the
     * absence of complaints.
     */
    @Test
    fun `a successful command reports its outcome with a duration`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"claim","seq":4,"epoch":"e1"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        val decoded = ProtocolJson.decodeFromString(
            CommandOutcomePayload.serializer(),
            f.transport.published.last().payload,
        )
        assertEquals(COMMAND_OUTCOME_KIND, decoded.kind)
        assertEquals("succeeded", decoded.outcome)
        assertEquals(null, decoded.reason)
        assertEquals(4L, decoded.seq)
        assertEquals("e1", decoded.epoch)
        assertEquals("audio", decoded.resourceType)
        assertTrue(decoded.durationMs >= 0)
    }

    /**
     * The failure path still reports, and still leaves the sequence mark
     * alone so the broker's QoS 1 redelivery can retry (#210/#161).
     */
    @Test
    fun `a failed command reports failed with a reason code`() = runTest {
        val f = Fixture(failConnectTimes = 1)
        f.transport.commands.send("""{"type":"claim","seq":1,"epoch":"e1"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        val decoded = ProtocolJson.decodeFromString(
            CommandOutcomePayload.serializer(),
            f.transport.published.last().payload,
        )
        assertEquals("failed", decoded.outcome)
        assertEquals("target_device_unreachable", decoded.reason)
    }

    /**
     * A command the gate discards is reported rather than dropped
     * silently. ADR 0019 tracks `superseded_by_newer_command` separately
     * from real failures - a superseded command is idempotency working
     * correctly, not a switch that went wrong - so it has to be
     * distinguishable in the data rather than invisible.
     */
    @Test
    fun `a superseded command is reported rather than silently discarded`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"claim","seq":2,"epoch":"e1"}""")
        f.transport.commands.send("""{"type":"release","seq":1,"epoch":"e1"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(emptyList(), f.gateway.disconnectCalls, "the stale release must not have run")
        val decoded = ProtocolJson.decodeFromString(
            CommandOutcomePayload.serializer(),
            f.transport.published.last().payload,
        )
        assertEquals("failed", decoded.outcome)
        assertEquals("superseded_by_newer_command", decoded.reason)
        assertEquals(1L, decoded.seq)
    }

    /**
     * A lost measurement must never become a deaf node. #161/#223's
     * lesson was that an exception escaping this loop leaves the adapter
     * silently unable to act on any later command - and on Android it
     * took the whole process down, with the OS restarting it in a loop.
     * An outcome publish is far less important than staying subscribed.
     */
    @Test
    fun `a failure to report an outcome does not end the command loop`() = runTest {
        val f = Fixture()
        f.transport.failPublishes = true
        f.transport.commands.send("""{"type":"claim"}""")
        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf(HEADSET), f.gateway.connectCalls)
        assertEquals(
            listOf(HEADSET),
            f.gateway.disconnectCalls,
            "the second command must still run after the first outcome failed to publish",
        )
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
     * #210 / ADR 0018 decision 1, end to end through the node rather
     * than against the gate alone.
     *
     * Commands ride MQTT at QoS 1 - at-*least*-once - so the broker is
     * entitled to redeliver, and does on reconnect. The redelivered
     * CLAIM here arrives after a newer RELEASE, and acting on it would
     * take the headset back from whichever device now holds it.
     */
    @Test
    fun `a claim redelivered after a newer release does not reconnect`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"claim","seq":1,"epoch":"e1"}""")
        f.transport.commands.send("""{"type":"release","seq":2,"epoch":"e1"}""")
        f.transport.commands.send("""{"type":"claim","seq":1,"epoch":"e1"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf(HEADSET), f.gateway.connectCalls, "the redelivered claim must not reconnect")
        assertEquals(listOf(HEADSET), f.gateway.disconnectCalls)
    }

    /**
     * The relay restarted: new epoch, counters back to 1. Every command
     * is below this node's mark and must be acted on anyway, or the
     * system deadlocks until adapter state is cleared by hand.
     */
    @Test
    fun `a command from a new relay epoch is acted on even though its seq is lower`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"claim","seq":9,"epoch":"e1"}""")
        f.transport.commands.send("""{"type":"release","seq":1,"epoch":"e2"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf(HEADSET), f.gateway.connectCalls)
        assertEquals(listOf(HEADSET), f.gateway.disconnectCalls, "a new epoch resets the mark")
    }

    /**
     * The relay half of #210 shipped before this half, so a build of
     * this adapter has already run against a relay that stamped
     * nothing. A node that discarded unsequenced commands would be
     * completely deaf rather than merely unprotected.
     */
    @Test
    fun `an unsequenced command is still honoured`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"claim","seq":5,"epoch":"e1"}""")
        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        assertEquals(listOf(HEADSET), f.gateway.disconnectCalls)
    }

    /**
     * A claim that throws has not happened - the headset was off, out of
     * range or busy (#161). The mark must stay where it is so the
     * broker's redelivery gets to retry it, rather than being marked
     * done and discarded forever.
     */
    @Test
    fun `a command that failed is retried when it is redelivered`() = runTest {
        val transport = FakeMqttTransport()
        val gateway = RecordingGateway(failConnectTimes = 1)
        val node = AndroidNode(ACCOUNT, NODE, HEADSET, transport, BluetoothConnectionManager(gateway))
        transport.commands.send("""{"type":"claim","seq":1,"epoch":"e1"}""")
        transport.commands.send("""{"type":"claim","seq":1,"epoch":"e1"}""")
        transport.commands.close()

        node.listenForCommands()

        assertEquals(listOf(HEADSET, HEADSET), gateway.connectCalls, "the failed claim must be retryable")
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

    // ---- holder state from the retained topic (#234) ----

    @Test
    fun `the retained state topic is subscribed to at its own QoS`() = runTest {
        val f = Fixture()
        f.transport.state.close()

        f.node.listenForState()

        assertEquals(listOf(STATE_TOPIC to 0), f.transport.subscriptions)
    }

    @Test
    fun `this node being holder is reported as holding the claim`() = runTest {
        val f = Fixture()
        f.transport.state.send("""{"holder":"$NODE"}""")
        f.transport.state.close()

        f.node.listenForState()

        assertEquals(true, f.node.holdsClaim())
    }

    @Test
    fun `another node being holder is reported as not holding`() = runTest {
        val f = Fixture()
        f.transport.state.send("""{"holder":"some-mac"}""")
        f.transport.state.close()

        f.node.listenForState()

        assertEquals(false, f.node.holdsClaim())
    }

    /**
     * `{"holder":null}` is a real answer - the relay saying nobody holds
     * it - and must not read the same as never having heard.
     */
    @Test
    fun `nobody holding is an answer not an absence`() = runTest {
        val f = Fixture()
        f.transport.state.send("""{"holder":null}""")
        f.transport.state.close()

        f.node.listenForState()

        assertEquals(false, f.node.holdsClaim())
    }

    /**
     * The third state. Before any retained message arrives there is no
     * honest answer, and the UI falls back rather than render a guess.
     */
    @Test
    fun `before any state arrives the holder is unknown`() = runTest {
        val f = Fixture()

        assertNull(f.node.holdsClaim())
    }

    /**
     * Same rule that makes `NodeStatus.Disconnected` outrank route
     * state: what we last heard says what was true then, not now.
     */
    @Test
    fun `a disconnected transport reports an unknown holder`() = runTest {
        val f = Fixture()
        f.transport.state.send("""{"holder":"$NODE"}""")
        f.transport.state.close()
        f.node.listenForState()
        assertEquals(true, f.node.holdsClaim())

        f.transport.connected = false

        assertNull(f.node.holdsClaim(), "a stale holder must not be presented as current")
    }

    /**
     * Same rule as `listenForCommands`: a malformed message from a newer
     * relay must not leave the notification frozen at a stale holder.
     */
    @Test
    fun `an undecodable state payload does not end the subscription`() = runTest {
        val f = Fixture()
        f.transport.state.send("not json")
        f.transport.state.send("""{"holder":"$NODE"}""")
        f.transport.state.close()

        f.node.listenForState()

        assertEquals(true, f.node.holdsClaim(), "the valid message after the bad one must still be read")
    }

    // ---- a revoked manual claim is ended, not suspended (#234 criterion 5) ----

    /**
     * The decision: a call that outranks a manual claim **ends** it. The
     * headset does not come back when the call finishes.
     */
    @Test
    fun `a relay release ends a manual claim this node was holding`() = runTest {
        val f = Fixture()
        f.node.emitEvent(EventKind.MANUAL_CLAIM, 0)
        assertTrue(f.node.isEventActive(EventKind.MANUAL_CLAIM))

        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()
        f.node.listenForCommands()

        assertFalse(f.node.isEventActive(EventKind.MANUAL_CLAIM), "the claim must be over, not merely unheld")
    }

    /**
     * Forgetting it locally is not enough, and this is the test that says
     * so. The relay keeps its own record per node; if it is never told,
     * `computeActiveHolder` hands the headset back the moment the call
     * ends - the *opposite* decision, implemented by accident.
     */
    @Test
    fun `the end of a revoked manual claim is published to the relay`() = runTest {
        val f = Fixture()
        f.node.emitEvent(EventKind.MANUAL_CLAIM, 0)

        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()
        f.node.listenForCommands()

        val ends = f.transport.published
            .filter { it.topic == EVENTS_TOPIC }
            .map { ProtocolJson.parseToJsonElement(it.payload) as JsonObject }
            .filter { it["kind"]?.jsonPrimitive?.content == "event_end" }
        assertEquals(1, ends.size)
        assertEquals("manual_claim", ends.single().getValue("type").jsonPrimitive.content)
    }

    /**
     * The consequence that makes the choice stick: #178's periodic
     * registration must not re-assert a claim the relay already revoked.
     */
    @Test
    fun `after a revoked claim registration no longer reports it`() = runTest {
        val f = Fixture()
        f.node.emitEvent(EventKind.MANUAL_CLAIM, 0)

        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()
        f.node.listenForCommands()
        f.node.register(MANIFEST)

        val registration = f.transport.published.last { it.topic == EVENTS_TOPIC }
        val body = ProtocolJson.parseToJsonElement(registration.payload) as JsonObject
        val active = (body.getValue("activeEvents") as JsonArray).map { it.jsonPrimitive.content }
        assertFalse(active.contains("manual_claim"))
    }

    /**
     * A release with no manual claim to revoke must not publish a
     * spurious end for a trigger that was never active.
     */
    @Test
    fun `a release without a manual claim publishes no end`() = runTest {
        val f = Fixture()
        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()

        f.node.listenForCommands()

        val ends = f.transport.published
            .map { ProtocolJson.parseToJsonElement(it.payload) }
            .filterIsInstance<JsonObject>()
            .filter { it["kind"]?.jsonPrimitive?.content == "event_end" }
        assertTrue(ends.isEmpty())
    }

    /**
     * Other triggers are untouched: they end when the underlying
     * activity ends, and a relay release is not that.
     */
    @Test
    fun `a relay release does not end a media trigger`() = runTest {
        val f = Fixture()
        f.node.emitEvent(EventKind.MEDIA, 0)

        f.transport.commands.send("""{"type":"release"}""")
        f.transport.commands.close()
        f.node.listenForCommands()

        assertTrue(f.node.isEventActive(EventKind.MEDIA))
    }
}
