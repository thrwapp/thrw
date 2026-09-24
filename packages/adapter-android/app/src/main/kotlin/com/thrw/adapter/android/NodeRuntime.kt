package com.thrw.adapter.android

import com.thrw.adapter.android.heartbeat.HeartbeatPublisher
import com.thrw.adapter.android.heartbeat.HeartbeatRunner
import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.triggers.CallTriggerMonitor
import com.thrw.adapter.android.registration.RegistrationPublisher
import com.thrw.adapter.android.registration.RegistrationRunner
import com.thrw.adapter.android.triggers.MediaTriggerMonitor
import com.thrw.adapter.android.triggers.VoipTriggerMonitor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * The composition root's testable half (#96's acceptance criterion 4: "a
 * testable factory function or dependency-injection seam"). Everything
 * here is plain Kotlin - no `android.app.Service`, no framework lifecycle
 * - so it's tested the same way `AndroidNodeTest.kt` already tests
 * [AndroidNode]: against fakes, with `runTest`.
 *
 * [AdapterForegroundService] is the untestable half: it constructs the
 * *real* dependencies ([AndroidNode], [CallTriggerMonitor],
 * [VoipTriggerMonitor] wired to android.bluetooth/android.telephony/
 * NotificationListenerService-backed implementations) and hands them to
 * this class. This class knows nothing about where they came from.
 */
class NodeRuntime(
    private val node: AndroidNode,
    private val callTriggerMonitor: CallTriggerMonitor,
    private val voipTriggerMonitor: VoipTriggerMonitor,
    private val mediaTriggerMonitor: MediaTriggerMonitor,
    private val heartbeatRunner: HeartbeatRunner = HeartbeatPublisher(node),
    private val registrationRunner: RegistrationRunner = RegistrationPublisher(),
) {
    /**
     * Registers [manifest], starts listening for relay commands, and
     * starts both trigger monitors - each its own coroutine launched in
     * [scope], so one throwing (or, for a monitor, its source flow simply
     * completing) doesn't take the others down. Returns immediately;
     * every launched coroutine keeps running until [scope] is cancelled.
     */
    fun start(scope: CoroutineScope, manifest: NodeManifest) {
        val registration = scope.launch { node.register(manifest) }
        scope.launch { node.listenForCommands() }
        // #234: the relay's holder, read from the retained state topic.
        // Its own coroutine rather than folded into the commands one, for
        // the reason every launch here is separate - one subscription
        // ending must not take another down, and a notification that has
        // stopped updating is a far smaller failure than a node that has
        // stopped hearing commands.
        scope.launch { node.listenForState() }
        scope.launch { callTriggerMonitor.run() }
        scope.launch { voipTriggerMonitor.run() }
        scope.launch { mediaTriggerMonitor.run() }
        // #142: without this the relay reaps this node ~90s after it
        // registers - and, since #130, publishes a RELEASE to it on the
        // way out, dropping the headset mid-call.
        //
        // Joins `registration` first rather than beating straight away:
        // the relay only subscribes to a node's heartbeat topic when it
        // sees that node's *registration* (`relay-service.ts`'s
        // `handleEvent` -> `trackHeartbeat`), so a beat published before
        // then lands on a topic nothing is listening to. Registration
        // also stamps liveness relay-side, so there's no gap to cover by
        // racing it.
        scope.launch {
            registration.join()
            heartbeatRunner.run()
        }
        // #178: the relay holds its node list purely in memory and learns
        // of a node only from a registration, so a relay restart (or an
        // MQTT reconnect) leaves this node invisible until it registers
        // again. Re-sending periodically is what closes that; each send
        // carries the currently-active triggers, so it reconciles rather
        // than merely re-announcing.
        scope.launch {
            registration.join()
            registrationRunner.run { node.register(manifest) }
        }
        // #182. Reconnecting restores the connection, not the relay's
        // memory of this node - the relay learns of a node only from a
        // registration and holds that in memory, so a node that silently
        // reconnects is connected but invisible, which is #178 by another
        // route. Waiting for the 2-minute timer would leave a window
        // where the headset cannot be arbitrated at all, and reconnect is
        // exactly when the relay's picture is most likely to be stale.
        //
        // Safe to do on every reconnect because #178 made registration a
        // statement of current state rather than an edge: it carries the
        // node's active triggers, so the relay reconciles instead of
        // being told something started.
        node.onReconnected {
            scope.launch { node.register(manifest) }
        }
    }
}
