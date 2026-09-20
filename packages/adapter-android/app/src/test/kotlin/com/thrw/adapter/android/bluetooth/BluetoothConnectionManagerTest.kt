package com.thrw.adapter.android.bluetooth

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Fakes the [BluetoothClassicGateway] boundary instead of mocking Android
 * framework internals (there is nothing to mock: this Gradle module has no
 * android.bluetooth classes on its classpath - see the gateway's kdoc).
 */
private class FakeBluetoothClassicGateway : BluetoothClassicGateway {
    val connectCalls = mutableListOf<String>()
    val disconnectCalls = mutableListOf<String>()
    var failNextConnect = false
    var failNextDisconnect = false

    /** What [isAudioRouteActive] reports; null means "cannot tell". */
    var routeActive: Boolean? = null

    override suspend fun isAudioRouteActive(deviceAddress: String): Boolean? = routeActive

    override suspend fun connect(deviceAddress: String) {
        connectCalls += deviceAddress
        if (failNextConnect) {
            failNextConnect = false
            throw IllegalStateException("simulated connect failure")
        }
    }

    override suspend fun disconnect(deviceAddress: String) {
        disconnectCalls += deviceAddress
        if (failNextDisconnect) {
            failNextDisconnect = false
            throw IllegalStateException("simulated disconnect failure")
        }
    }
}

private const val ADDRESS = "AA:BB:CC:DD:EE:FF"
private const val OTHER_ADDRESS = "11:22:33:44:55:66"

class BluetoothConnectionManagerTest {
    /**
     * ADR 0018 decision 3, corrected by #186. A multipoint headset can
     * keep its Bluetooth link to this device while the route moves to
     * another, so the cached CONNECTED state is not evidence that a claim
     * is unnecessary. Skipping on it silently drops a claim that was
     * genuinely needed - no log, no retry, no audio.
     */
    @Test
    fun `a claim is re-issued when the cached state says connected but the route is elsewhere`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)

        manager.connect(ADDRESS)
        assertEquals(listOf(ADDRESS), gateway.connectCalls)

        // Same device, still believed connected - but the route has gone.
        gateway.routeActive = false
        manager.connect(ADDRESS)

        assertEquals(
            listOf(ADDRESS, ADDRESS),
            gateway.connectCalls,
            "the claim must be re-issued when the route is not actually here",
        )
    }

    /**
     * The other direction: when the route really is here, a repeat claim
     * must still be skipped, or every reconciliation would pointlessly
     * tear the connection down and rebuild it.
     */
    @Test
    fun `a claim is still skipped when the route really is here`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)

        manager.connect(ADDRESS)
        gateway.routeActive = true
        manager.connect(ADDRESS)

        assertEquals(listOf(ADDRESS), gateway.connectCalls)
    }

    /**
     * `null` is "cannot tell", not "no". An unreadable route must not
     * override a cached state that may well be correct.
     */
    @Test
    fun `an unknown route does not override the cached state`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)

        manager.connect(ADDRESS)
        gateway.routeActive = null
        manager.connect(ADDRESS)

        assertEquals(listOf(ADDRESS), gateway.connectCalls)
    }

    @Test
    fun `unknown device reports disconnected`() = runTest {
        val manager = BluetoothConnectionManager(FakeBluetoothClassicGateway())

        assertEquals(BluetoothConnectionState.DISCONNECTED, manager.connectionState(ADDRESS))
    }

    @Test
    fun `connect transitions to connected and calls the gateway once`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)

        manager.connect(ADDRESS)

        assertEquals(BluetoothConnectionState.CONNECTED, manager.connectionState(ADDRESS))
        assertEquals(listOf(ADDRESS), gateway.connectCalls)
    }

    @Test
    fun `connect while already connected is a no-op`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)

        manager.connect(ADDRESS)
        manager.connect(ADDRESS)

        assertEquals(BluetoothConnectionState.CONNECTED, manager.connectionState(ADDRESS))
        assertEquals(listOf(ADDRESS), gateway.connectCalls)
    }

    @Test
    fun `failed connect reverts to disconnected and propagates the error`() = runTest {
        val gateway = FakeBluetoothClassicGateway().apply { failNextConnect = true }
        val manager = BluetoothConnectionManager(gateway)

        assertFailsWith<IllegalStateException> { manager.connect(ADDRESS) }

        assertEquals(BluetoothConnectionState.DISCONNECTED, manager.connectionState(ADDRESS))
    }

    @Test
    fun `connect after a failed attempt is retried`() = runTest {
        val gateway = FakeBluetoothClassicGateway().apply { failNextConnect = true }
        val manager = BluetoothConnectionManager(gateway)

        assertFailsWith<IllegalStateException> { manager.connect(ADDRESS) }
        manager.connect(ADDRESS)

        assertEquals(BluetoothConnectionState.CONNECTED, manager.connectionState(ADDRESS))
        assertEquals(listOf(ADDRESS, ADDRESS), gateway.connectCalls)
    }

    @Test
    fun `disconnect transitions a connected device back to disconnected`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)
        manager.connect(ADDRESS)

        manager.disconnect(ADDRESS)

        assertEquals(BluetoothConnectionState.DISCONNECTED, manager.connectionState(ADDRESS))
        assertEquals(listOf(ADDRESS), gateway.disconnectCalls)
    }

    @Test
    fun `disconnecting an unknown device is a no-op that never calls the gateway`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)

        manager.disconnect(ADDRESS)

        assertEquals(BluetoothConnectionState.DISCONNECTED, manager.connectionState(ADDRESS))
        assertTrue(gateway.disconnectCalls.isEmpty())
    }

    @Test
    fun `disconnecting an already disconnected device does not call the gateway again`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)
        manager.connect(ADDRESS)
        manager.disconnect(ADDRESS)

        manager.disconnect(ADDRESS)

        assertEquals(listOf(ADDRESS), gateway.disconnectCalls)
    }

    @Test
    fun `even a failed disconnect leaves state disconnected`() = runTest {
        val gateway = FakeBluetoothClassicGateway().apply { failNextDisconnect = true }
        val manager = BluetoothConnectionManager(gateway)
        manager.connect(ADDRESS)

        assertFailsWith<IllegalStateException> { manager.disconnect(ADDRESS) }

        assertEquals(BluetoothConnectionState.DISCONNECTED, manager.connectionState(ADDRESS))
    }

    @Test
    fun `each device address is tracked independently`() = runTest {
        val gateway = FakeBluetoothClassicGateway()
        val manager = BluetoothConnectionManager(gateway)

        manager.connect(ADDRESS)

        assertEquals(BluetoothConnectionState.CONNECTED, manager.connectionState(ADDRESS))
        assertEquals(BluetoothConnectionState.DISCONNECTED, manager.connectionState(OTHER_ADDRESS))
    }
}
