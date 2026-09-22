package com.thrw.adapter.android.bluetooth

import android.util.Log
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout

/**
 * The bound every adapter enforces on a claim or release (ADR 0019).
 *
 * **This must stay equal to `packages/protocol`'s
 * `COMMAND_OUTCOME_TIMEOUT_MS` and `adapter-mac`'s
 * `commandOutcomeTimeout`.** Three hand-written declarations of one
 * number, and nothing else catches them drifting — the same situation as
 * the heartbeat interval, which carries the same warning.
 *
 * #206 criterion 2 requires it be identical everywhere: an adapter
 * choosing its own bound makes the aggregate switch success rate
 * meaningless, because an outcome would not mean the same thing in every
 * row.
 *
 * It guarantees **termination, not latency** — ADR 0007 owns latency,
 * with its own 3.5-4s p95 SLO, against a 3-5s real switch on the
 * reference hardware.
 */
const val COMMAND_OUTCOME_TIMEOUT_MS = 8_000L

/**
 * Manages Bluetooth Classic connect/disconnect for paired headsets,
 * one device at a time (per ADR 0002: sequential handoff, not
 * multipoint - this class has no notion of "the other device", it just
 * tracks state per address).
 *
 * This is local device control only. It does not talk to a relay, does
 * not implement the node interface, and does not do any trigger
 * detection - see the follow-up issues referenced from #66.
 */
class BluetoothConnectionManager(
    private val gateway: BluetoothClassicGateway,
) {
    private val mutex = Mutex()
    private val states = mutableMapOf<String, BluetoothConnectionState>()

    /**
     * Connects to [deviceAddress]. A no-op if that device is already
     * connected or a connection attempt is already in flight.
     *
     * On failure, state reverts to [BluetoothConnectionState.DISCONNECTED]
     * and the underlying exception is rethrown.
     */
    /** Pass-through to the gateway - see [BluetoothClassicGateway.isAudioRouteActive]. */
    suspend fun isAudioRouteActive(deviceAddress: String): Boolean? =
        gateway.isAudioRouteActive(deviceAddress)

    suspend fun connect(deviceAddress: String) {
        val previous = mutex.withLock {
            val previous = states[deviceAddress]
            if (previous != BluetoothConnectionState.CONNECTED && previous != BluetoothConnectionState.CONNECTING) {
                states[deviceAddress] = BluetoothConnectionState.CONNECTING
            }
            previous
        }
        var shouldConnect = previous != BluetoothConnectionState.CONNECTED &&
            previous != BluetoothConnectionState.CONNECTING

        // ADR 0018 decision 3, corrected by #186: the skip must be
        // decided on the actual route, not on this cached belief. The
        // cache is exactly what a multipoint headset invalidates - the
        // phone can take the route while this device keeps its Bluetooth
        // link, leaving `states` saying CONNECTED when audio is playing
        // somewhere else entirely. Skipping then silently drops a claim
        // that was genuinely needed: no log, no retry, no audio.
        //
        // Only CONNECTED is second-guessed. CONNECTING means a claim is
        // already in flight, and re-entering would issue a duplicate.
        // A `null` route reading means "cannot tell", which is no reason
        // to override a cached state that may well be right.
        if (!shouldConnect && previous == BluetoothConnectionState.CONNECTED) {
            if (gateway.isAudioRouteActive(deviceAddress) == false) {
                mutex.withLock { states[deviceAddress] = BluetoothConnectionState.CONNECTING }
                shouldConnect = true
            }
        }
        if (!shouldConnect) {
            // #244 criterion 2. Skipping a genuinely concurrent claim, or
            // one for a device that really does hold the route, is
            // correct. Doing it *silently* is what made the stuck case
            // undiagnosable: the only external symptom was a route_drift
            // every two minutes with no reason attached.
            Log.i(TAG, "claim skipped for $deviceAddress (state=$previous)")
            return
        }

        try {
            // #244. Bounded so `states` always resolves. Before this, a
            // gateway.connect that never returned left the state at
            // CONNECTING with neither the success nor the catch path
            // running - and the CONNECTING branch above returns early
            // *without* the route second-guess that rescues a stale
            // CONNECTED, so every later claim for this device was skipped
            // silently for the life of the process.
            //
            // Observed on the reference Pixel: relay holder, connected,
            // registering every 120s, no connection attempt for over half
            // an hour. Restarting the service - which clears this map and
            // nothing else - fixed it immediately.
            withTimeout(COMMAND_OUTCOME_TIMEOUT_MS) {
                gateway.connect(deviceAddress)
            }
            mutex.withLock { states[deviceAddress] = BluetoothConnectionState.CONNECTED }
        } catch (e: TimeoutCancellationException) {
            // Caught ahead of the general handler below: withTimeout's
            // exception is a CancellationException, so letting it reach a
            // bare `catch (e: Exception)` would be indistinguishable from
            // the caller cancelling us. They need different reason codes
            // once ADR 0019's outcome reporting lands (`timed_out` vs the
            // caller going away), and lumping them together is how this
            // class of failure stayed invisible.
            mutex.withLock { states[deviceAddress] = BluetoothConnectionState.DISCONNECTED }
            Log.e(
                TAG,
                "connect did not resolve within ${COMMAND_OUTCOME_TIMEOUT_MS}ms for $deviceAddress " +
                    "- giving up so later claims are not skipped",
            )
            throw e
        } catch (e: Exception) {
            mutex.withLock { states[deviceAddress] = BluetoothConnectionState.DISCONNECTED }
            throw e
        }
    }

    /**
     * Disconnects [deviceAddress]. A no-op if that device is unknown,
     * already disconnected, or already disconnecting.
     */
    suspend fun disconnect(deviceAddress: String) {
        val shouldDisconnect = mutex.withLock {
            when (states[deviceAddress]) {
                null, BluetoothConnectionState.DISCONNECTED, BluetoothConnectionState.DISCONNECTING -> false
                else -> {
                    states[deviceAddress] = BluetoothConnectionState.DISCONNECTING
                    true
                }
            }
        }
        if (!shouldDisconnect) return

        try {
            gateway.disconnect(deviceAddress)
        } finally {
            mutex.withLock { states[deviceAddress] = BluetoothConnectionState.DISCONNECTED }
        }
    }

    /** Current known connection state for [deviceAddress]; unknown devices report DISCONNECTED. */
    suspend fun connectionState(deviceAddress: String): BluetoothConnectionState =
        mutex.withLock { states[deviceAddress] ?: BluetoothConnectionState.DISCONNECTED }

    private companion object {
        private const val TAG = "BluetoothConnection"
    }
}
