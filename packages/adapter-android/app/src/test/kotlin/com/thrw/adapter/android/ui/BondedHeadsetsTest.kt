package com.thrw.adapter.android.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

private val AIRPODS = BondedDevice(name = "Tom's AirPods Pro", address = "AA:BB:CC:DD:EE:FF")
private val UNNAMED = BondedDevice(name = null, address = "11:22:33:44:55:66")

class BondedHeadsetsTest {
    @Test
    fun `permission not granted takes priority over the bonded-devices list`() {
        val state = BondedHeadsets.state(permissionGranted = false, bondedDevices = listOf(AIRPODS))

        assertIs<BondedHeadsetsState.PermissionNotGranted>(state)
    }

    @Test
    fun `no bonded devices is reported explicitly, not as an empty devices list`() {
        val state = BondedHeadsets.state(permissionGranted = true, bondedDevices = emptyList())

        assertIs<BondedHeadsetsState.NoDevicesBonded>(state)
    }

    @Test
    fun `bonded devices are reported in the order the platform returned them`() {
        val state = BondedHeadsets.state(permissionGranted = true, bondedDevices = listOf(AIRPODS, UNNAMED))

        val devices = assertIs<BondedHeadsetsState.Devices>(state)
        assertEquals(listOf(AIRPODS, UNNAMED), devices.devices)
    }

    @Test
    fun `permission not granted wins even when devices are somehow also present`() {
        // Shouldn't happen in practice (the real caller only has a device
        // list once permission is granted), but the precedence is a
        // decision this type makes, not an assumption about its caller -
        // worth pinning down explicitly.
        val state = BondedHeadsets.state(permissionGranted = false, bondedDevices = listOf(AIRPODS))

        assertIs<BondedHeadsetsState.PermissionNotGranted>(state)
    }

    @Test
    fun `label combines name and address when a name is present`() {
        assertEquals("Tom's AirPods Pro (AA:BB:CC:DD:EE:FF)", BondedHeadsets.label(AIRPODS))
    }

    @Test
    fun `label falls back to the bare address when there is no name`() {
        assertEquals("11:22:33:44:55:66", BondedHeadsets.label(UNNAMED))
    }

    @Test
    fun `label falls back to the bare address when the name is blank`() {
        assertEquals("11:22:33:44:55:66", BondedHeadsets.label(UNNAMED.copy(name = "   ")))
    }
}
