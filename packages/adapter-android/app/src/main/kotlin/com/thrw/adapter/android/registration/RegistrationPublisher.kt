package com.thrw.adapter.android.registration

import kotlinx.coroutines.delay

/**
 * The seam [com.thrw.adapter.android.NodeRuntime] depends on, for exactly
 * the reason
 * [com.thrw.adapter.android.heartbeat.HeartbeatRunner] exists: [run]
 * never returns on its own, so a test driving `NodeRuntime.start` with
 * `advanceUntilIdle()` under `runTest`'s virtual clock would hang
 * forever - there is always another `delay` scheduled, so the scheduler
 * never goes idle. Depending on the interface lets those tests supply a
 * runner that terminates.
 */
fun interface RegistrationRunner {
    suspend fun run(register: suspend () -> Unit)
}

/**
 * Re-sends this node's registration periodically, so a relay that lost
 * its picture of the system gets it back (#178).
 *
 * The relay learns of a node **only** from a registration message. It
 * holds that entirely in memory, so a relay restart - or merely its MQTT
 * connection dropping and reconnecting, which is how this was found -
 * leaves every already-running node invisible to it: they keep
 * heartbeating into a void and never get arbitrated again. Before this,
 * the only cure was restarting each adapter by hand.
 *
 * Each registration carries the node's currently-active triggers
 * (`RegistrationPayload.activeEvents`), so the relay reconciles to the
 * truth rather than inferring it from edges it may have missed. That is
 * what makes re-registering safe to do repeatedly: it is a statement of
 * current state, not an event.
 *
 * Unlike [com.thrw.adapter.android.heartbeat.HeartbeatPublisher], this
 * **delays before its first send**, because
 * [com.thrw.adapter.android.NodeRuntime] has already registered once by
 * the time this starts. Sending again immediately would be pure noise.
 */
class RegistrationPublisher(
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
) : RegistrationRunner {
    override suspend fun run(register: suspend () -> Unit) {
        while (true) {
            delay(intervalMs)
            register()
        }
    }

    companion object {
        /**
         * Two minutes: the worst-case window in which a restarted relay
         * is blind to a node that is running but not currently emitting
         * anything.
         *
         * Deliberately much slower than the 30s heartbeat. The heartbeat
         * answers "are you still there", which the relay needs promptly
         * to avoid reaping a live node; this answers "here is everything
         * about me", which only matters after the rare event of the relay
         * losing its state. `adapter-mac`'s
         * `defaultRegistrationInterval` is the same constant on the other
         * side of the same behaviour.
         */
        const val DEFAULT_INTERVAL_MS = 120_000L
    }
}
