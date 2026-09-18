package com.thrw.adapter.android.heartbeat

import kotlinx.coroutines.delay

/**
 * Publishes this node's liveness beat so the relay doesn't reap it.
 *
 * Deliberately **not** part of the Kotlin `NodeInterface` mirror (#142),
 * for exactly the reason
 * [com.thrw.adapter.android.triggers.EventLifecycle] isn't either: that
 * interface is a frozen cross-platform contract at four methods
 * (`register`, `emitEvent`, `onClaim`, `onRelease` - ADR 0001,
 * AGENTS.md), and growing it needs an ADR plus human review. The
 * heartbeat *topic* and its interval are already specified in
 * architecture.md's topic table, so publishing to it is fulfilling that
 * contract rather than changing it - this separate seam is how both stay
 * true.
 */
interface HeartbeatSink {
    suspend fun publishHeartbeat()
}

/**
 * The seam [com.thrw.adapter.android.NodeRuntime] actually depends on.
 *
 * Exists because [HeartbeatPublisher.run] never returns on its own,
 * unlike `CallTriggerMonitor.run`/`VoipTriggerMonitor.run`, which end
 * when their source flow completes. A test driving `NodeRuntime.start`
 * with `advanceUntilIdle()` under `runTest`'s virtual clock would
 * otherwise hang forever - there is always another `delay` scheduled, so
 * the scheduler never goes idle (confirmed the hard way: it hung the
 * whole Android suite before this interface existed). Depending on the
 * interface lets those tests supply a runner that terminates, matching
 * how the monitors already behave under test.
 */
fun interface HeartbeatRunner {
    suspend fun run()
}

/**
 * Beats once, then once per [intervalMs], until the calling coroutine is
 * cancelled.
 *
 * Why this exists: before #142 neither adapter published a heartbeat,
 * while `services/relay-hosted`'s `sweepHeartbeats` reaped any node that
 * hadn't beaten within its timeout - so every real node was dropped ~90s
 * after registering and (after #130 wired `PriorityEngine.forgetNode`
 * into that same sweep) had a RELEASE published to it, disconnecting the
 * headset mid-call.
 *
 * The first beat is sent *before* the first [delay], so a caller starting
 * this right after registration doesn't spend a third of the relay's
 * budget silent. That's only correct because [com.thrw.adapter.android.NodeRuntime]
 * waits for registration to finish before starting this loop: the relay
 * doesn't subscribe to a node's heartbeat topic until it has seen that
 * node register (`relay-service.ts`'s `handleEvent` -> `trackHeartbeat`),
 * so a beat sent any earlier is published to nobody.
 */
class HeartbeatPublisher(
    private val sink: HeartbeatSink,
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
) : HeartbeatRunner {
    override suspend fun run() {
        while (true) {
            sink.publishHeartbeat()
            delay(intervalMs)
        }
    }

    companion object {
        /**
         * architecture.md's "MQTT topic design" table specifies this
         * topic as `QoS 0, ~30s`. `services/relay-hosted`'s
         * `DEFAULT_HEARTBEAT_TIMEOUT_MS` is 90s - deliberately 3x this,
         * so a couple of missed beats is normal jitter and three in a row
         * is "gone".
         *
         * **These two numbers must stay in that 3:1 relationship.**
         * Changing one without the other silently changes how long a dead
         * node keeps its claim - or starts reaping live ones.
         * `adapter-mac`'s `defaultHeartbeatInterval` is the same constant
         * on the other side of the same contract.
         */
        const val DEFAULT_INTERVAL_MS = 30_000L
    }
}
