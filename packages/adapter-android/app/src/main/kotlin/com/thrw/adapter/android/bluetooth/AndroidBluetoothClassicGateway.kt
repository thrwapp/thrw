package com.thrw.adapter.android.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Real [BluetoothClassicGateway], backed by
 * `android.bluetooth.BluetoothAdapter`/`BluetoothDevice`/`BluetoothSocket` -
 * the concrete implementation this interface's kdoc anticipated landing
 * "once that [AGP] swap happens" (#66 -> #96; see docs/handoffs/96.md for
 * the actual swap).
 *
 * [deviceAddress] must already be a bonded (paired) device -
 * `BluetoothAdapter.getRemoteDevice` doesn't pair, it only wraps an
 * address the OS Bluetooth stack already knows about. Pairing a new
 * headset is a separate, out-of-scope flow (no UI for it exists yet).
 *
 * Connects over RFCOMM using the Serial Port Profile UUID
 * ([SERIAL_PORT_PROFILE_UUID]), the standard channel a classic-Bluetooth
 * headset's SPP/HFP service record exposes.
 *
 * `BLUETOOTH_CONNECT` (API 31+, declared in `AndroidManifest.xml`) is
 * required for every call here. This class does not itself request it at
 * runtime - no `Activity` exists yet to host that permission dialog
 * (docs/handoffs/96.md); `@SuppressLint` documents that gap at each call
 * site rather than hiding it.
 */
class AndroidBluetoothClassicGateway(context: Context) : BluetoothClassicGateway {
    private val adapter: BluetoothAdapter =
        (context.applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    private val mutex = Mutex()
    private val openSockets = mutableMapOf<String, BluetoothSocket>()

    @SuppressLint("MissingPermission")
    override suspend fun connect(deviceAddress: String) {
        withContext(Dispatchers.IO) {
            val device = adapter.getRemoteDevice(deviceAddress)
            val socket = device.createRfcommSocketToServiceRecord(SERIAL_PORT_PROFILE_UUID)
            try {
                socket.connect()
            } catch (e: Exception) {
                runCatching { socket.close() }
                throw e
            }
            mutex.withLock { openSockets[deviceAddress] = socket }
        }
    }

    @SuppressLint("MissingPermission")
    override suspend fun disconnect(deviceAddress: String) {
        withContext(Dispatchers.IO) {
            val socket = mutex.withLock { openSockets.remove(deviceAddress) }
            socket?.close()
        }
    }

    companion object {
        /** Serial Port Profile UUID - the standard RFCOMM channel a classic-Bluetooth headset exposes. */
        val SERIAL_PORT_PROFILE_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }
}
