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
import kotlinx.coroutines.delay
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
        val driven = applyToProfiles(deviceAddress, "connect")
        awaitProfileState(deviceAddress, driven, BluetoothProfile.STATE_CONNECTED, "connect")
    }

    override suspend fun disconnect(deviceAddress: String) = withContext(Dispatchers.IO) {
        val driven = applyToProfiles(deviceAddress, "disconnect")
        awaitProfileState(deviceAddress, driven, BluetoothProfile.STATE_DISCONNECTED, "disconnect")
    }

    /**
     * Suspends until one of the profiles actually driven reports
     * [targetState] for [deviceAddress] (#257).
     *
     * ## Why this has to exist
     *
     * `BluetoothA2dp.connect(device)` returns a boolean meaning *"the
     * request was accepted"*, not *"the device is connected"* - the
     * connection completes asynchronously. Without this wait, [connect]
     * returned in ~18ms on the reference Pixel while the headset took
     * roughly 9-10 seconds to actually attach.
     *
     * That was not merely an inaccurate number. ADR 0019's outcome
     * reporting (#206) then logged `succeeded` for a claim before
     * anything had happened, so:
     *
     * - a claim that was accepted and *then refused* - observed three
     *   times in a row on 2026-09-22, ACL up and A2DP declined - was
     *   recorded as a success;
     * - aggregate switch success rate and ADR 0007's
     *   `claim_roundtrip_ms` would have shown Android as ~100x faster
     *   than macOS and near-perfectly reliable, breaking ADR 0019's
     *   central premise that an outcome means the same thing in every
     *   row;
     * - #244's 8s bound had nothing to bound, since a call returning in
     *   18ms can never time out.
     *
     * ## Why polling rather than a broadcast receiver
     *
     * `getConnectionState` is **public** API - no new hidden-API
     * dependency, unlike the `connect`/`disconnect` above. A
     * `BroadcastReceiver` on `ACTION_CONNECTION_STATE_CHANGED` would be
     * more event-driven but adds registration lifecycle to a class that
     * has none, for a wait that is already bounded elsewhere.
     *
     * **Deliberately no timeout of its own.**
     * `BluetoothConnectionManager` wraps every call in
     * `withTimeout(COMMAND_OUTCOME_TIMEOUT_MS)` (#244), so a device that
     * never reaches the target state surfaces as that bound firing -
     * which is exactly the `timed_out` outcome ADR 0019 wants, rather
     * than a second competing deadline with its own semantics.
     */
    @SuppressLint("MissingPermission")
    private suspend fun awaitProfileState(
        deviceAddress: String,
        driven: List<Pair<String, BluetoothProfile>>,
        targetState: Int,
        method: String,
    ) {
        val device = adapter.getRemoteDevice(deviceAddress)
        // Only meaningful while waiting for CONNECTED: a refusal shows up
        // as the state going CONNECTING and then back to DISCONNECTED.
        // Tracked so that is reported as the failure it is, immediately,
        // rather than spinning until the outer 8s bound and surfacing as
        // `timed_out` - a wrong reason code *and* eight seconds spent
        // waiting for something already known to have failed.
        //
        // Only concluded *after* CONNECTING has been observed, because
        // the state is legitimately still DISCONNECTED for a moment
        // right after the request is accepted.
        var sawConnecting = false
        while (true) {
            val states = driven.map { (_, proxy) ->
                try {
                    proxy.getConnectionState(device)
                } catch (e: SecurityException) {
                    // Permission revoked mid-operation. Treated as
                    // "reached" rather than "not there yet", so the outer
                    // bound ends this instead of it spinning silently
                    // with no explanation.
                    Log.w(TAG, "getConnectionState denied while awaiting $method for $deviceAddress", e)
                    targetState
                }
            }
            if (states.any { it == targetState }) return

            if (targetState == BluetoothProfile.STATE_CONNECTED) {
                if (states.any { it == BluetoothProfile.STATE_CONNECTING }) sawConnecting = true
                if (sawConnecting && states.all { it == BluetoothProfile.STATE_DISCONNECTED }) {
                    throw IllegalStateException(
                        "$deviceAddress accepted the $method request and then refused it - " +
                            "every driven profile returned to DISCONNECTED",
                    )
                }
            }
            delay(PROFILE_STATE_POLL_MS)
        }
    }

    /**
     * Invokes [method] on every available audio profile proxy, and
     * returns the ones that accepted the request.
     *
     * Throws only if *no* profile could be driven at all - a device that
     * genuinely has no A2DP (a headset that is call-only, say) shouldn't
     * fail the whole operation when HFP worked. `BluetoothConnectionManager`
     * treats a throw as "the claim failed", so the distinction matters.
     *
     * The return value is what [awaitProfileState] waits on (#257):
     * waiting on a profile that refused the request would hang until the
     * outer bound fired, reporting `timed_out` for what was really an
     * immediate refusal on that profile.
     */
    @SuppressLint("MissingPermission")
    private suspend fun applyToProfiles(
        deviceAddress: String,
        method: String,
    ): List<Pair<String, BluetoothProfile>> {
        val device = adapter.getRemoteDevice(deviceAddress)
        val proxies = audioProfileProxies()
        if (proxies.isEmpty()) {
            throw IllegalStateException("No A2DP or HFP profile proxy available - cannot $method $deviceAddress")
        }

        val failures = mutableListOf<String>()
        val driven = mutableListOf<Pair<String, BluetoothProfile>>()
        for ((label, proxy) in proxies) {
            try {
                invokeProfileMethod(proxy, method, device)
                driven += label to proxy
            } catch (e: Exception) {
                failures += "$label: ${e.message}"
                Log.w(TAG, "$method via $label failed for $deviceAddress", e)
            }
        }
        if (driven.isEmpty()) {
            throw IllegalStateException("$method failed on every audio profile - ${failures.joinToString("; ")}")
        }
        return driven
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

    /**
     * Reads A2DP's *active* device - the one media audio is actually
     * routed to (#191).
     *
     * `getActiveDevice()` is hidden, reached the same way and for the
     * same reason as `connect`/`disconnect` above: there is no public
     * equivalent. Unlike those, a failure here is **not** an error -
     * returning `null` means "cannot tell", which the relay treats as no
     * information rather than as a disagreement. So a future Android
     * blocking this degrades reconciliation to nothing, instead of
     * feeding the relay a fabricated `false`.
     *
     * A2DP only: it carries media, and it is A2DP's active device that
     * `dumpsys bluetooth_manager` reports as `mActiveDevice`. HFP has its
     * own active device for call audio; tracking both is only meaningful
     * once resources are typed (ADR 0015 / #171), and conflating them
     * would report "I hold the headset" for a device that only has the
     * call channel.
     */
    override suspend fun isAudioRouteActive(deviceAddress: String): Boolean? {
        val proxy = proxyLock.withLock {
            if (a2dp == null) a2dp = awaitProxy(BluetoothProfile.A2DP) as BluetoothA2dp?
            a2dp
        } ?: return null

        return try {
            val method = proxy.javaClass.getMethod("getActiveDevice")
            val active = method.invoke(proxy) as BluetoothDevice?
            active?.address?.equals(deviceAddress, ignoreCase = true) ?: false
        } catch (e: Exception) {
            Log.w(TAG, "getActiveDevice is not reachable - route state is unknown (#191)", e)
            null
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
     * back (Bluetooth off, profile unsupported), so a `false` return
     * resumes with `null` rather than suspending - the caller treats a
     * missing proxy as "that profile isn't available".
     *
     * **That covers the `false` return only.** If `getProfileProxy`
     * returns `true` and `onServiceConnected` is then never called, this
     * suspends indefinitely. An earlier version of this comment claimed
     * the guarantee unconditionally, which was wrong.
     *
     * Whether that is what hung the reference Pixel in #244 was **not**
     * established: the state was cleared by a restart before it could be
     * instrumented, and this is only the most plausible of several
     * candidates. So the fix is deliberately not here —
     * [BluetoothConnectionManager] bounds the whole connect with
     * `COMMAND_OUTCOME_TIMEOUT_MS`, which covers a hang wherever it
     * originates, including one nobody has thought of. Cancellation does
     * propagate into the [suspendCancellableCoroutine] below, so that
     * outer bound genuinely unsticks this rather than leaking it.
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

        /**
         * How often [awaitProfileState] re-reads the profile state (#257).
         *
         * 100ms against a connection that takes seconds: fine-grained
         * enough that the reported `durationMs` is not dominated by poll
         * granularity, cheap enough to be irrelevant next to the
         * Bluetooth work itself. There is no upper bound here on purpose
         * - `BluetoothConnectionManager`'s `withTimeout` owns that.
         */
        private const val PROFILE_STATE_POLL_MS = 100L
    }
}
