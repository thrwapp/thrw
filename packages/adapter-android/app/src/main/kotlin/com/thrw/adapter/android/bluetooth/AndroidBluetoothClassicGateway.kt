package com.thrw.adapter.android.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.util.Log
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Moves a paired headset's **audio route** to or from this device, by
 * connecting and disconnecting its A2DP (media) and HFP (call) profiles.
 *
 * ## Why not an RFCOMM socket
 *
 * This used to open an RFCOMM/SPP socket
 * (`createRfcommSocketToServiceRecord(SPP_UUID)`). That could never work,
 * for two independent reasons, both confirmed against real AirPods Pro 2
 * on a Pixel 10 Pro (#162):
 *
 * 1. **Headphones don't run a Serial Port Profile server.** The reference
 *    AirPods advertise exactly `0000110b` (A2DP Sink), `0000110e` (AVRCP)
 *    and `0000111e` (HFP) - no `00001101` (SPP). So the socket connect
 *    failed outright with `read failed, socket might closed or timeout`.
 * 2. **An RFCOMM socket does not move an audio route anyway.** Audio
 *    lives on A2DP and HFP. Opening an unrelated serial channel is not
 *    the same thing, even against a device that would accept one.
 *
 * This is the same class of mistake `adapter-mac` corrected in #101,
 * where CoreBluetooth (BLE) could connect a peripheral but could not move
 * the route, and `IOBluetooth`'s baseband connection was the real answer.
 *
 * ## The hidden-API dependency, stated plainly
 *
 * `BluetoothA2dp.connect/disconnect` and `BluetoothHeadset.connect/disconnect`
 * are **not public API**. There is no public way for an ordinary app to
 * force a specific device's profile connection; the public surface only
 * lets you *observe* it (`getConnectionState`, used below without
 * reflection). So these are invoked reflectively.
 *
 * Verified permitted on Android 16 / `targetSdk 35`, which logs the
 * access explicitly:
 *
 * ```
 * hiddenapi: Accessing hidden method Landroid/bluetooth/BluetoothA2dp;->connect(...)
 * (runtime_flags=0, domain=platform, api=unsupported) ... using reflection: allowed
 * ```
 *
 * `api=unsupported` means exactly what it says: Google may move these to
 * the blocklist in any future Android release, at which point the
 * reflective lookup throws. That is why every reflective call here fails
 * loudly with a clear message rather than silently doing nothing - a
 * future OS update turning handoff off must be obvious, not mysterious.
 * See docs/handoffs/162.md and the ADR this warranted.
 *
 * ## Both profiles, not just A2DP
 *
 * A2DP carries media and HFP carries call audio. architecture.md's rule 1
 * is *calls*, so connecting A2DP alone would leave the highest-priority
 * trigger routing to the wrong device. Both are connected on claim and
 * disconnected on release; a device that doesn't support one of them
 * simply reports no proxy for it and is skipped.
 */
class AndroidBluetoothClassicGateway(context: Context) : BluetoothClassicGateway {
    private val appContext = context.applicationContext
    private val adapter: BluetoothAdapter =
        (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    private val proxyLock = Mutex()
    private var a2dp: BluetoothA2dp? = null
    private var headset: BluetoothHeadset? = null

    override suspend fun connect(deviceAddress: String) = withContext(Dispatchers.IO) {
        applyToProfiles(deviceAddress, "connect")
    }

    override suspend fun disconnect(deviceAddress: String) = withContext(Dispatchers.IO) {
        applyToProfiles(deviceAddress, "disconnect")
    }

    /**
     * Invokes [method] on every available audio profile proxy.
     *
     * Throws only if *no* profile could be driven at all - a device that
     * genuinely has no A2DP (a headset that is call-only, say) shouldn't
     * fail the whole operation when HFP worked. `BluetoothConnectionManager`
     * treats a throw as "the claim failed", so the distinction matters.
     */
    @SuppressLint("MissingPermission")
    private suspend fun applyToProfiles(deviceAddress: String, method: String) {
        val device = adapter.getRemoteDevice(deviceAddress)
        val proxies = audioProfileProxies()
        if (proxies.isEmpty()) {
            throw IllegalStateException("No A2DP or HFP profile proxy available - cannot $method $deviceAddress")
        }

        val failures = mutableListOf<String>()
        var succeeded = false
        for ((label, proxy) in proxies) {
            try {
                invokeProfileMethod(proxy, method, device)
                succeeded = true
            } catch (e: Exception) {
                failures += "$label: ${e.message}"
                Log.w(TAG, "$method via $label failed for $deviceAddress", e)
            }
        }
        if (!succeeded) {
            throw IllegalStateException("$method failed on every audio profile - ${failures.joinToString("; ")}")
        }
    }

    /**
     * Reflective invocation of the hidden profile method. Kept in one
     * place so there's a single, well-documented point where this
     * dependency lives, and a single place that has to change if a future
     * Android blocks it (or, better, ever exposes a public equivalent).
     */
    private fun invokeProfileMethod(proxy: BluetoothProfile, method: String, device: BluetoothDevice) {
        val m = try {
            proxy.javaClass.getMethod(method, BluetoothDevice::class.java)
        } catch (e: NoSuchMethodException) {
            throw IllegalStateException(
                "$method is not reachable on ${proxy.javaClass.simpleName} - this Android version has " +
                    "blocked the hidden API thrw relies on to move the audio route (#162)",
                e,
            )
        }
        val result = m.invoke(proxy, device)
        if (result == false) {
            throw IllegalStateException("${proxy.javaClass.simpleName}.$method returned false for ${device.address}")
        }
    }

    /** Cached proxies, acquired once. Empty entries are simply absent. */
    private suspend fun audioProfileProxies(): List<Pair<String, BluetoothProfile>> = proxyLock.withLock {
        if (a2dp == null) a2dp = awaitProxy(BluetoothProfile.A2DP) as BluetoothA2dp?
        if (headset == null) headset = awaitProxy(BluetoothProfile.HEADSET) as BluetoothHeadset?
        listOfNotNull(
            a2dp?.let { "A2DP" to it as BluetoothProfile },
            headset?.let { "HFP" to it as BluetoothProfile },
        )
    }

    /**
     * `getProfileProxy` is callback-based and can legitimately never call
     * back (Bluetooth off, profile unsupported), so this resumes with
     * `null` rather than suspending forever - the caller treats a missing
     * proxy as "that profile isn't available", not as a hang.
     */
    @SuppressLint("MissingPermission")
    private suspend fun awaitProxy(profile: Int): BluetoothProfile? =
        suspendCancellableCoroutine { cont ->
            val listener = object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(p: Int, proxy: BluetoothProfile) {
                    if (cont.isActive) cont.resume(proxy)
                }

                override fun onServiceDisconnected(p: Int) {
                    // The proxy died; drop the cached reference so the
                    // next call re-acquires rather than using a stale one.
                    when (p) {
                        BluetoothProfile.A2DP -> a2dp = null
                        BluetoothProfile.HEADSET -> headset = null
                    }
                }
            }
            if (!adapter.getProfileProxy(appContext, listener, profile)) {
                if (cont.isActive) cont.resume(null)
            }
        }

    private companion object {
        private const val TAG = "BluetoothGateway"
    }
}
