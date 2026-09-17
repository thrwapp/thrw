package com.thrw.adapter.android

import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.triggers.CallTriggerMonitor
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
) {
    /**
     * Registers [manifest], starts listening for relay commands, and
     * starts both trigger monitors - each its own coroutine launched in
     * [scope], so one throwing (or, for a monitor, its source flow simply
     * completing) doesn't take the others down. Returns immediately;
     * every launched coroutine keeps running until [scope] is cancelled.
     */
    fun start(scope: CoroutineScope, manifest: NodeManifest) {
        scope.launch { node.register(manifest) }
        scope.launch { node.listenForCommands() }
        scope.launch { callTriggerMonitor.run() }
        scope.launch { voipTriggerMonitor.run() }
    }
}
