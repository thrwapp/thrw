package com.thrw.adapter.android

import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.heartbeat.HeartbeatSink
import com.thrw.adapter.android.mqtt.MqttTransport
import com.thrw.adapter.android.protocol.CommandPayload
import com.thrw.adapter.android.protocol.CommandType
import com.thrw.adapter.android.protocol.EventEndPayload
import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.EventPayload
import com.thrw.adapter.android.protocol.NodeInterface
import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.protocol.Priority
import com.thrw.adapter.android.protocol.ProtocolJson
import com.thrw.adapter.android.protocol.RegistrationPayload
import com.thrw.adapter.android.protocol.Topics
import com.thrw.adapter.android.protocol.TopicQos
import com.thrw.adapter.android.triggers.EventLifecycle
import kotlinx.serialization.json.Json

/**
 * The Android adapter as a node on the relay: `packages/protocol`'s node
 * interface, over this device's own MQTT connection to the relay's broker
 * (architecture.md, "System components").
 *
 * Out of scope on purpose:
 * - **The connection state machine** (idle / pre-claim / claim / active).
 *   Frozen contract per ADR 0010 / 0011 / 0013 - a separate ADR plus human
 *   review, not a routine agent PR. [onClaim] / [onRelease] here are the
 *   plain side-effecting hooks the TypeScript interface declares; nothing
 *   in this class tracks or transitions a node state.
 * - **Trigger detection** (TelephonyManager, NotificationListener, ...).
 *   [emitEvent] / [endEvent] are called *by* that layer, which lives in
 *   `triggers/` (`CallTriggerMonitor`, `VoipTriggerMonitor`); this class
 *   just publishes what it's handed. Media triggers aren't detected yet.
 * - **Priority rules.** Server-side in the relay, "never duplicated in
 *   adapters" (architecture.md). This node reports; it does not decide.
 */
class AndroidNode(
    private val accountId: String,
    private val nodeId: String,
    private val headsetAddress: String,
    private val transport: MqttTransport,
    private val bluetooth: BluetoothConnectionManager,
    private val json: Json = ProtocolJson,
) : NodeInterface, EventLifecycle, HeartbeatSink {

    /**
     * Publishes this node's manifest so the relay's device registry knows
     * what the node can do. Rides the node's events topic (the only
     * node-publishes topic in the frozen topic set) inside a
     * [RegistrationPayload] envelope - see docs/handoffs/67.md.
     */
    override suspend fun register(manifest: NodeManifest) {
        publishToEvents(
            json.encodeToString(RegistrationPayload.serializer(), RegistrationPayload(manifest = manifest)),
        )
    }

    /** Publishes a trigger to the events topic at QoS 1 per `TopicQos`. */
    override suspend fun emitEvent(type: EventKind, priority: Priority) {
        publishToEvents(json.encodeToString(EventPayload.serializer(), EventPayload(type, priority)))
    }

    /**
     * The symmetric partner of [emitEvent]: the [type] trigger this node
     * reported has stopped. Publishes an [EventEndPayload] on the same
     * events topic at the same QoS.
     *
     * Added here, in the adapter, rather than to the Kotlin
     * `NodeInterface` mirror or to `packages/protocol` - that type is a
     * frozen cross-platform contract and growing it needs an ADR plus
     * human review (AGENTS.md). See [EventLifecycle] for the full
     * argument, and docs/handoffs/68.md.
     */
    override suspend fun endEvent(type: EventKind) {
        publishToEvents(json.encodeToString(EventEndPayload.serializer(), EventEndPayload(type = type)))
    }

    /** Claim won: connect the headset to this device. */
    override suspend fun onClaim() {
        bluetooth.connect(headsetAddress)
    }

    /** Claim lost (or released): disconnect the headset from this device. */
    override suspend fun onRelease() {
        bluetooth.disconnect(headsetAddress)
    }

    /**
     * Subscribes to this node's commands topic and dispatches each
     * relay-issued command to [onClaim] / [onRelease]. Suspends until the
     * calling coroutine is cancelled.
     *
     * Unparseable payloads are skipped rather than thrown: a malformed
     * message from a newer relay must not tear down the subscription and
     * leave this node deaf to the *next*, valid, claim.
     */
    suspend fun listenForCommands() {
        transport.subscribe(Topics.commands(accountId, nodeId), TopicQos.COMMANDS_QOS)
            .collect { payload ->
                val command = runCatching {
                    json.decodeFromString(CommandPayload.serializer(), payload)
                }.getOrNull()
                when (command?.type) {
                    CommandType.CLAIM -> onClaim()
                    CommandType.RELEASE -> onRelease()
                    null -> Unit
                }
            }
    }

    /**
     * [HeartbeatSink] conformance (#142) - liveness only, so the relay's
     * `sweepHeartbeats` doesn't reap this node.
     *
     * Empty payload, deliberately: architecture.md's topic table
     * specifies this topic as `QoS 0, ~30s` and says nothing about a
     * body, and `relay-core`'s `subscribeHeartbeat` ignores the payload
     * entirely - arrival *is* the signal. Inventing a body here would
     * create something a future relay might start parsing, for no current
     * benefit.
     *
     * QoS 0 ([TopicQos.HEARTBEAT_QOS]), also from that table: at-most-once
     * is right for a signal that repeats every 30s and is only read as
     * "recently alive" - redelivering a stale beat would be misleading.
     */
    override suspend fun publishHeartbeat() {
        transport.publish(
            topic = Topics.heartbeat(accountId, nodeId),
            payload = "",
            qos = TopicQos.HEARTBEAT_QOS,
            retained = false,
        )
    }

    private suspend fun publishToEvents(payload: String) {
        transport.publish(
            topic = Topics.events(accountId, nodeId),
            payload = payload,
            qos = TopicQos.EVENTS_QOS,
            retained = false,
        )
    }
}
