package com.thrw.adapter.android.bluetooth

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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
        if (!shouldConnect) return

        try {
            gateway.connect(deviceAddress)
            mutex.withLock { states[deviceAddress] = BluetoothConnectionState.CONNECTED }
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
}
