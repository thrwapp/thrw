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

    /**
     * Whether [deviceAddress] is the device audio is actually **routed
     * to** right now (#191) - not merely whether it is connected.
     *
     * That distinction is the point. Multipoint headsets hold links to
     * several hosts at once: measured on the reference hardware with the
     * *phone* holding the route, the Mac simultaneously reported the
     * AirPods as connected while its own output was its speakers. So
     * connection state answers yes on both devices and is useless as a
     * holder signal - a relay reconciling against it sees two holders and
     * corrects forever.
     *
     * Returns `null` when it cannot be determined, which must not be
     * smoothed into `false`: `false` asserts this device does not hold
     * the headset and is grounds for corrective action, while `null`
     * means "no information" and leaves the relay's record alone.
     */
    suspend fun isAudioRouteActive(deviceAddress: String): Boolean? = null
}
