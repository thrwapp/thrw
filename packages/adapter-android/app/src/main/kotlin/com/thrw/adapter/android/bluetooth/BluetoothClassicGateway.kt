package com.thrw.adapter.android.bluetooth

/**
 * Thin seam over the platform Bluetooth Classic connect/disconnect calls
 * that [BluetoothConnectionManager] depends on, modeled on the
 * android.bluetooth.BluetoothAdapter / BluetoothDevice / BluetoothSocket
 * flow (getRemoteDevice -> createRfcommSocketToServiceRecord -> connect,
 * and socket.close() to disconnect).
 *
 * This module's Gradle build (see app/build.gradle.kts) is still the
 * plain Kotlin/JVM scaffold, not the Android Gradle Plugin, so
 * android.bluetooth classes aren't on its compile classpath yet - this
 * interface is the boundary a real, android.bluetooth-backed
 * implementation will sit behind once that swap happens. Tests fake this
 * interface directly rather than mocking Android framework internals.
 */
interface BluetoothClassicGateway {
    suspend fun connect(deviceAddress: String)

    suspend fun disconnect(deviceAddress: String)
}
