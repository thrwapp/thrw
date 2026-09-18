package com.thrw.adapter.android.ui

/**
 * One bonded (paired) Bluetooth device, as much as the provisioning
 * picker needs - name and address. Pure Kotlin mirror of the two
 * `BluetoothDevice` fields this screen reads, kept free of
 * `android.bluetooth` so the picker logic below is unit-testable (see
 * [BondedHeadsets] and [BondedDeviceSource]'s own kdoc for why the real
 * lookup isn't).
 */
data class BondedDevice(
    val name: String?,
    val address: String,
)

/**
 * What [ProvisioningActivity]'s headset picker should show, computed from
 * whether `BLUETOOTH_CONNECT` is granted and what
 * `BluetoothAdapter.getBondedDevices()` returned (#117 acceptance
 * criterion 2: the "no bonded devices" and "permission not yet granted"
 * states need explicit handling, not an empty picker with no
 * explanation).
 */
sealed interface BondedHeadsetsState {
    /** `BLUETOOTH_CONNECT` isn't granted yet - the real device list can't be read at all. */
    data object PermissionNotGranted : BondedHeadsetsState

    /** Permission is granted, but nothing is paired with this host yet. */
    data object NoDevicesBonded : BondedHeadsetsState

    /** At least one bonded device, in the order the platform returned them. */
    data class Devices(val devices: List<BondedDevice>) : BondedHeadsetsState
}

/**
 * Turns a permission-granted flag and a raw bonded-device list into
 * [BondedHeadsetsState] - both fed in rather than read directly, the same
 * fake-seam pattern [AdapterPermissions.missing]/[NotificationAccess.isGranted]
 * use for OS-boundary calls this module's stubbed `android.jar` can't
 * exercise for real. The real lookup lives in [BondedDeviceSource].
 *
 * #117's picker replaces the free-text headset-address field outright
 * rather than offering both (the issue's own "your judgment call,
 * document which"): any address the picker wouldn't list can't actually
 * be connected to anyway -
 * [com.thrw.adapter.android.bluetooth.AndroidBluetoothClassicGateway]
 * requires the device to already be bonded - so a free-text fallback
 * would just re-open the exact wrong/mistyped-address failure mode this
 * issue exists to close, for no offsetting benefit.
 */
object BondedHeadsets {
    fun state(permissionGranted: Boolean, bondedDevices: List<BondedDevice>): BondedHeadsetsState = when {
        !permissionGranted -> BondedHeadsetsState.PermissionNotGranted
        bondedDevices.isEmpty() -> BondedHeadsetsState.NoDevicesBonded
        else -> BondedHeadsetsState.Devices(bondedDevices)
    }

    /**
     * The label shown per picker entry: `"name (AA:BB:CC:DD:EE:FF)"`, or
     * just the address if the device has no name (`BluetoothDevice.getName()`
     * can return `null`).
     */
    fun label(device: BondedDevice): String {
        val name = device.name
        return if (name.isNullOrBlank()) device.address else "$name (${device.address})"
    }
}
