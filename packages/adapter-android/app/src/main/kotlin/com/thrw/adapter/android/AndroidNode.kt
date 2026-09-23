package com.thrw.adapter.android

import android.util.Log
import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.heartbeat.HeartbeatSink
import com.thrw.adapter.android.mqtt.MqttTransport
import com.thrw.adapter.android.audio.HandoverAudioGate
import com.thrw.adapter.android.audio.NoOpHandoverAudioGate
import com.thrw.adapter.android.protocol.CommandFailureReason
import com.thrw.adapter.android.protocol.CommandOutcome
import com.thrw.adapter.android.protocol.CommandOutcomePayload
import com.thrw.adapter.android.protocol.CommandPayload
import com.thrw.adapter.android.protocol.CommandSequenceGate
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
import kotlinx.coroutines.TimeoutCancellationException
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
    /**
     * ADR 0018 decision 1 (#210). Discards a relay command that is
     * older than one this node has already acted on. Defaults to an
     * in-memory mark so tests and a node built without a Context still
     * work; [AdapterForegroundService] supplies the persisted one,
     * which is what makes the guarantee survive a process restart.
     */
    private val sequenceGate: CommandSequenceGate = CommandSequenceGate(),
    /**
     * ADR 0022 (#254). Silences this device's audio across the handover
     * window, so the ~2.7s where no device holds the headset does not
     * come out of the built-in speaker.
     *
     * Defaults to a no-op rather than a failure: a node built without
     * one behaves exactly as it did before ADR 0022 - leaking audio as
     * it always has - rather than refusing to hand over at all.
     */
    private val audioGate: HandoverAudioGate = NoOpHandoverAudioGate,
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
                // ADR 0018 decision 1 (#210). Commands ride QoS 1, so the
                // broker may redeliver - and does, on reconnect. Acting
                // on a redelivered CLAIM that arrives after a newer
                // RELEASE would re-claim the headset from whoever now
                // holds it.
                //
                // Checked before the try/catch rather than inside it: a
                // discard is not a failure, and logging it as one would
                // bury the failures that matter.
                if (command != null && !sequenceGate.accepts(command)) {
                    Log.i(TAG, "Discarding stale ${command.type} (seq=${command.seq}, epoch=${command.epoch})")
                    // ADR 0019 / #206. Reported, not dropped silently -
                    // that is what `superseded_by_newer_command` is for,
                    // and ADR 0019 tracks it separately from real
                    // failures because a superseded command is
                    // idempotency working correctly, not a switch that
                    // went wrong.
                    reportOutcome(
                        command,
                        CommandOutcome.FAILED,
                        CommandFailureReason.SUPERSEDED_BY_NEWER_COMMAND,
                        durationMs = 0,
                    )
                    return@collect
                }
                // ADR 0019's durationMs. Monotonic, not wall clock: this
                // feeds a latency SLO (ADR 0007), and a clock adjustment
                // mid-claim would otherwise produce a negative or wildly
                // inflated reading that silently skews it.
                val startedAt = System.nanoTime()
                // ADR 0022. Silence before the mechanical work, because
                // the window opens the moment the old host lets go - not
                // when the new one finishes. Both commands silence; only
                // a claim restores, and only once the outcome is known.
                //
                // On release we deliberately never restore: the user has
                // moved to another device, and continuing to play here
                // is never what they wanted. That is what the platform
                // itself does on AUDIO_BECOMING_NOISY.
                if (command != null) audioGate.silence()
                try {
                    when (command?.type) {
                        CommandType.CLAIM -> onClaim()
                        CommandType.RELEASE -> onRelease()
                        null -> Unit
                    }
                    // Only after the command actually succeeded. A claim
                    // that threw has not happened, and leaving the mark
                    // where it is lets a redelivery retry it.
                    if (command != null) sequenceGate.record(command)
                    if (command?.type == CommandType.CLAIM) audioGate.restore()
                    reportOutcome(command, CommandOutcome.SUCCEEDED, null, elapsedMs(startedAt))
                } catch (e: TimeoutCancellationException) {
                    // Caught ahead of CancellationException below: #244's
                    // bound throws this, and ADR 0019 separates "the
                    // headset said no" from "nothing answered at all".
                    // Falling through to the cancellation branch would
                    // lose the measurement *and* kill the loop.
                    Log.e(TAG, "Command ${command?.type} timed out - staying subscribed", e)
                    // ADR 0022: restore on *every* terminal outcome, not
                    // only success. A user left silenced because a claim
                    // timed out would be a worse bug than the leak this
                    // prevents - and a timeout is exactly when the
                    // headset did not arrive, so the audio has nowhere
                    // to go but here.
                    if (command?.type == CommandType.CLAIM) audioGate.restore()
                    reportOutcome(command, CommandOutcome.TIMED_OUT, null, elapsedMs(startedAt))
                } catch (e: CancellationException) {
                    // Restored before rethrowing: the runtime is shutting
                    // us down, and leaving the user's media paused as a
                    // parting gesture would be indistinguishable from a
                    // bug.
                    if (command?.type == CommandType.CLAIM) audioGate.restore()
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "Command ${command?.type} failed - staying subscribed", e)
                    if (command?.type == CommandType.CLAIM) audioGate.restore()
                    reportOutcome(
                        command,
                        CommandOutcome.FAILED,
                        CommandFailureReason.TARGET_DEVICE_UNREACHABLE,
                        elapsedMs(startedAt),
                    )
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

    /**
     * ADR 0019 / #206 stage 2 - tells the relay how a command ended.
     *
     * **Never throws, and never ends the command loop.** A failure to
     * report an outcome is a lost measurement; a failure to keep
     * listening is a node that goes deaf, which is #161/#223 all over
     * again. Those are not remotely the same severity, so this swallows
     * its own publish errors after logging them.
     *
     * [CancellationException] is re-thrown: that is structured
     * concurrency stopping us, not a publish failure, and swallowing it
     * would break cancellation.
     */
    private suspend fun reportOutcome(
        command: CommandPayload?,
        outcome: CommandOutcome,
        reason: CommandFailureReason?,
        durationMs: Long,
    ) {
        try {
            publishToEvents(
                ProtocolJson.encodeToString(
                    CommandOutcomePayload.serializer(),
                    CommandOutcomePayload(
                        epoch = command?.epoch,
                        seq = command?.seq,
                        resourceType = RESOURCE.wire,
                        outcome = outcome.wire,
                        reason = reason?.wire,
                        durationMs = durationMs,
                    ),
                ),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Could not report ${outcome.wire} outcome for ${command?.type}", e)
        }
    }

    /** Whole milliseconds since a [System.nanoTime] reading, floored at zero. */
    private fun elapsedMs(startedAtNanos: Long): Long =
        ((System.nanoTime() - startedAtNanos) / 1_000_000).coerceAtLeast(0)
}

/** This adapter manages the headset audio connection (ADR 0015). */
private val RESOURCE = ResourceType.AUDIO
