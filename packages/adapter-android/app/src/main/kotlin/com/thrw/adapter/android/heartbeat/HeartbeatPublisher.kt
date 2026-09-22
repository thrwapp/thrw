package com.thrw.adapter.android.heartbeat

import android.util.Log
import kotlinx.coroutines.CancellationException
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
    /**
     * Beats forever. **A failed beat does not end the loop** (#236).
     *
     * This used to call [HeartbeatSink.publishHeartbeat] bare in the loop
     * body, so one throw ended it permanently -
     * [com.thrw.adapter.android.NodeRuntime] catches and logs that, and
     * nothing restarts it. A single transient publish failure therefore
     * stopped this node heartbeating for the rest of the process's life
     * while it stayed connected and kept re-registering.
     *
     * The consequence is not a quiet degradation. The relay seeds node
     * liveness from each registration (`relay-service.ts`'s `handleEvent`
     * -> `trackHeartbeat`) and reaps at 90s, and reaping drops every
     * signal the node had via `PriorityEngine.forgetNode`. A node that
     * registers but never beats takes the headset on every registration
     * and loses it 90s later, forever; two of them ping-pong. Observed in
     * production for nine and a half hours overnight with nobody using
     * either device.
     *
     * Retrying is safe: the beat is a bare liveness ping at QoS 0 carrying
     * no state, so a lost one has no consequence beyond being lost. The
     * retry cadence is just [intervalMs] - a failure still falls through
     * to the [delay], so a broker that is down cannot make this a hot
     * loop.
     *
     * [CancellationException] is re-thrown rather than caught as a
     * failure: it is how structured concurrency stops this coroutine, and
     * swallowing it would both break cancellation and log an error on
     * every ordinary service shutdown. Mirrors `adapter-mac`'s
     * `HeartbeatPublisher.run`.
     */
    override suspend fun run() {
        // Logged on transition only, not per beat: a broker down for an
        // hour would otherwise write 120 identical lines, and the signal
        // worth having is "when did it break" and "did it come back".
        var isFailing = false
        while (true) {
            try {
                sink.publishHeartbeat()
                if (isFailing) {
                    isFailing = false
                    Log.i(TAG, "heartbeat resumed")
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!isFailing) {
                    isFailing = true
                    Log.e(TAG, "heartbeat publish failed, retrying every ${intervalMs}ms", e)
                }
            }
            delay(intervalMs)
        }
    }

    companion object {
        private const val TAG = "HeartbeatPublisher"

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
