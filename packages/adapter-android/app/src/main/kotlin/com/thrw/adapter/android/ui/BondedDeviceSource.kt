package com.thrw.adapter.android.ui

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.content.Context

/**
 * The real `android.bluetooth`-backed source of [BondedDevice]s that
 * [ProvisioningActivity] feeds into [BondedHeadsets.state].
 *
 * Not unit tested: real `BluetoothAdapter`/`BluetoothDevice` calls return
 * stubbed values under this module's `android.jar`
 * (`testOptions.unitTests.isReturnDefaultValues = true`, see
 * `app/build.gradle.kts`) - the same reason
 * [com.thrw.adapter.android.bluetooth.AndroidBluetoothClassicGateway]
 * itself has no test of its own. [BondedHeadsets.state] is the part of
 * this feature that's actually tested; this is the thin, untestable glue
 * that supplies its input for real.
 */
object BondedDeviceSource {
    /**
     * `BluetoothAdapter.getBondedDevices()` requires `BLUETOOTH_CONNECT`
     * (API 31+) - callers must have already confirmed it's granted
     * ([AdapterPermissions]) before calling this; it's suppressed here
     * rather than checked, matching every other real Bluetooth call site
     * in this module.
     */
    @SuppressLint("MissingPermission")
    fun bondedDevices(context: Context): List<BondedDevice> {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return emptyList()
        return adapter.bondedDevices.orEmpty().map { BondedDevice(name = it.name, address = it.address) }
    }
}
