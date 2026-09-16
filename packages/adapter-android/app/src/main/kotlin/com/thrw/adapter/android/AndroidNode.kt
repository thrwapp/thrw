package com.thrw.adapter.android

import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.mqtt.MqttTransport
import com.thrw.adapter.android.protocol.CommandPayload
import com.thrw.adapter.android.protocol.CommandType
import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.EventPayload
import com.thrw.adapter.android.protocol.NodeInterface
import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.protocol.Priority
import com.thrw.adapter.android.protocol.ProtocolJson
import com.thrw.adapter.android.protocol.RegistrationPayload
import com.thrw.adapter.android.protocol.Topics
import com.thrw.adapter.android.protocol.TopicQos
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
 *   [emitEvent] is called *by* that layer, which is a follow-up issue.
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
) : NodeInterface {

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

    private suspend fun publishToEvents(payload: String) {
        transport.publish(
            topic = Topics.events(accountId, nodeId),
            payload = payload,
            qos = TopicQos.EVENTS_QOS,
            retained = false,
        )
    }
}
