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
    suspend fun connect(deviceAddress: String) {
        val shouldConnect = mutex.withLock {
            when (states[deviceAddress]) {
                BluetoothConnectionState.CONNECTED, BluetoothConnectionState.CONNECTING -> false
                else -> {
                    states[deviceAddress] = BluetoothConnectionState.CONNECTING
                    true
                }
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
