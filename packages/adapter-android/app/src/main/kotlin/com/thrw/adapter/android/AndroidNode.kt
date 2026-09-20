package com.thrw.adapter.android

import android.util.Log
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
import com.thrw.adapter.android.protocol.RESOURCE_AUDIO
import com.thrw.adapter.android.protocol.ResourceType
import com.thrw.adapter.android.status.NodeStatus
import com.thrw.adapter.android.status.nodeStatus
import com.thrw.adapter.android.protocol.RegistrationPayload
import com.thrw.adapter.android.protocol.Topics
import com.thrw.adapter.android.protocol.TopicQos
import com.thrw.adapter.android.triggers.EventLifecycle
import com.thrw.adapter.android.triggers.RouteTransition
import com.thrw.adapter.android.triggers.bypassesSelfCooldown
import com.thrw.adapter.android.triggers.SelfCooldown
import kotlin.coroutines.cancellation.CancellationException
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
    /**
     * ADR 0010 point 1 (#167). Armed by [onClaim]/[onRelease]; while
     * active, trigger reports from the monitors are suppressed so thrw
     * doesn't misread its own Bluetooth side effects as new triggers.
     * Injectable so tests don't wait on wall time.
     */
    private val selfCooldown: SelfCooldown = SelfCooldown(),
    /** #191 - suppresses route observations taken mid-transition. */
    private val routeTransition: RouteTransition = RouteTransition(),
) : NodeInterface, EventLifecycle, HeartbeatSink {

    /**
     * Publishes this node's manifest so the relay's device registry knows
     * what the node can do. Rides the node's events topic (the only
     * node-publishes topic in the frozen topic set) inside a
     * [RegistrationPayload] envelope - see docs/handoffs/67.md.
     */
    override suspend fun register(manifest: NodeManifest) {
        publishToEvents(
            json.encodeToString(
                RegistrationPayload.serializer(),
                RegistrationPayload(
                    manifest = manifest,
                    activeEvents = activeEventsSnapshot(),
                    observedRoutes = observedRoutes(),
                ),
            ),
        )
    }

    /**
     * What this node has reported as active and not yet ended (#178).
     *
     * Only triggers this node actually *published* are tracked: a trigger
     * the self-cooldown suppressed was never told to the relay, so
     * including it here would leak it out on the next periodic
     * registration and undo the suppression (#167).
     */
    private val activeEvents = linkedSetOf<EventKind>()
    private val activeEventsLock = Any()

    /**
     * The resource this adapter manages (ADR 0015 / #171).
     *
     * A constant rather than a parameter: this adapter controls the
     * headset audio connection and nothing else, which is exactly what
     * its manifest declares. A `hid` adapter would be a different node.
     */
    private val resource get() = RESOURCE

    /**
     * This node's current status, for display (#213).
     *
     * Asks the transport and the gateway directly rather than caching: a
     * cached status is exactly what goes stale during the silent
     * failures this is meant to expose.
     */
    suspend fun status(): NodeStatus =
        nodeStatus(transport.isConnected(), bluetooth.isAudioRouteActive(headsetAddress))

    /**
     * Runs [handler] whenever the transport re-establishes a dropped
     * connection (#182) - see [MqttTransport.onReconnected].
     */
    fun onReconnected(handler: () -> Unit) {
        transport.onReconnected(handler)
    }

    /**
     * This node's observed audio route (#191), or an empty map when it
     * cannot honestly be reported.
     *
     * Omitted in two cases, both meaning "no information" rather than
     * "no": the gateway cannot read the route, or a claim/release is
     * still settling. A snapshot taken mid-transition reports "I do not
     * hold this" while the relay correctly believes this node does, and
     * the relay would then correct a transition that was simply still
     * happening - on a 2-minute cadence, forever.
     */
    private suspend fun observedRoutes(): Map<String, Boolean> {
        if (routeTransition.isSettling()) return emptyMap()
        val holds = bluetooth.isAudioRouteActive(headsetAddress) ?: return emptyMap()
        return mapOf(RESOURCE_AUDIO to holds)
    }

    private fun activeEventsSnapshot(): List<EventKind> =
        synchronized(activeEventsLock) { activeEvents.toList() }

    /** Publishes a trigger to the events topic at QoS 1 per `TopicQos`. */
    override suspend fun emitEvent(type: EventKind, priority: Priority) {
        if (!type.bypassesSelfCooldown() && suppressedBySelfCooldown("emitEvent($type)")) return
        publishToEvents(json.encodeToString(EventPayload.serializer(), EventPayload(type, priority)))
        synchronized(activeEventsLock) { activeEvents.add(type) }
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
        // Forgotten locally **before** the cooldown check, and regardless
        // of whether it is published (#183).
        //
        // The trigger really has ended - the monitor has already cleared
        // its own flag and will never retry. If a suppressed end also
        // left this entry in place, the node would keep reporting the
        // trigger as active on every periodic registration, and #178's
        // reconciliation would *perpetuate* the stranded signal rather
        // than repair it. For `call` that is the highest-priority signal
        // in the system, pinned to this device indefinitely.
        //
        // Removing it instead creates a deliberate, temporary divergence:
        // the relay still believes the trigger is active, this node says
        // otherwise, and the next registration settles it in favour of
        // the truth - within one interval rather than never.
        synchronized(activeEventsLock) { activeEvents.remove(type) }
        if (!type.bypassesSelfCooldown() && suppressedBySelfCooldown("endEvent($type)")) return
        publishToEvents(json.encodeToString(EventEndPayload.serializer(), EventEndPayload(type = type)))
    }

    /**
     * Claim won: connect the headset to this device.
     *
     * Arms the self-cooldown afterwards (#167): connecting the headset
     * changes this device's audio routing, which the media monitor would
     * otherwise report as a fresh trigger.
     */
    override suspend fun onClaim() {
        routeTransition.begin()
        try {
            bluetooth.connect(headsetAddress)
        } finally {
            routeTransition.end()
        }
        selfCooldown.arm()
    }

    /**
     * Claim lost (or released): disconnect the headset from this device.
     *
     * Armed on the way out even if the disconnect threw: the headset may
     * well have gone anyway, and a failed release is exactly when a
     * spurious self-triggered event is most likely.
     */
    override suspend fun onRelease() {
        routeTransition.begin()
        try {
            bluetooth.disconnect(headsetAddress)
        } finally {
            routeTransition.end()
            selfCooldown.arm()
        }
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
        transport.subscribe(Topics.commands(accountId, nodeId, RESOURCE), TopicQos.COMMANDS_QOS)
            .collect { payload ->
                val command = runCatching {
                    json.decodeFromString(CommandPayload.serializer(), payload)
                }.getOrNull()
                // A headset that is off, out of range, busy, or simply
                // doesn't support what we asked makes onClaim/onRelease
                // throw. That must not tear down this subscription - the
                // same discipline the unparseable-payload case above
                // already follows, and for the same reason: a node that
                // stops listening is deaf to the *next*, satisfiable
                // claim. Before #161 this propagated all the way out and
                // killed the whole adapter process (confirmed on real
                // hardware - a failed AirPods connect took the service
                // down and Android restarted it in a loop).
                //
                // CancellationException is deliberately not swallowed:
                // that's the runtime shutting this coroutine down, not a
                // Bluetooth failure, and catching it would break
                // cancellation.
                try {
                    when (command?.type) {
                        CommandType.CLAIM -> onClaim()
                        CommandType.RELEASE -> onRelease()
                        null -> Unit
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "Command ${command?.type} failed - staying subscribed", e)
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

    /**
     * Suppression applies to *trigger reporting only*. Relay commands are
     * unaffected - [listenForCommands] still honours a CLAIM arriving
     * inside the window, because the cooldown exists to stop thrw talking
     * to itself, not to make it deaf (#167 acceptance criterion 2).
     */
    private fun suppressedBySelfCooldown(what: String): Boolean {
        if (!selfCooldown.isActive()) return false
        Log.i(TAG, "Self-cooldown active - suppressing $what (ADR 0010)")
        return true
    }

    private companion object {
        private const val TAG = "AndroidNode"
    }

    private suspend fun publishToEvents(payload: String) {
        transport.publish(
            topic = Topics.events(accountId, nodeId, RESOURCE),
            payload = payload,
            qos = TopicQos.EVENTS_QOS,
            retained = false,
        )
    }
}

/** This adapter manages the headset audio connection (ADR 0015). */
private val RESOURCE = ResourceType.AUDIO
