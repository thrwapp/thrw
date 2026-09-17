package com.thrw.adapter.android.triggers

import kotlinx.coroutines.flow.Flow

/**
 * The three phone call states `TelephonyManager` reports, one-for-one:
 * `CALL_STATE_IDLE`, `CALL_STATE_RINGING`, `CALL_STATE_OFFHOOK`.
 *
 * [OFFHOOK] is the one that means "a call is happening": the platform uses
 * it both for an answered incoming call and for an outgoing call from the
 * moment it's dialed, which is exactly the pair of cases this adapter has
 * to claim the headset for.
 */
enum class PhoneCallState {
    IDLE,
    RINGING,
    OFFHOOK,
}

/**
 * Thin seam over `TelephonyManager`'s call-state stream that
 * [CallTriggerMonitor] depends on, modeled on the modern listener flow:
 * `TelephonyManager.registerTelephonyCallback(executor, callback)` with a
 * `TelephonyCallback.CallStateListener` (API 31+; the deprecated
 * `PhoneStateListener.onCallStateChanged` on older releases), guarded by
 * the `READ_PHONE_STATE` permission.
 *
 * Same reason this is an interface as `BluetoothClassicGateway`: this
 * Gradle module is still the plain Kotlin/JVM scaffold rather than the
 * Android Gradle Plugin (see app/build.gradle.kts), so `TelephonyManager`
 * isn't on the compile classpath, and real call events can't be raised in
 * the Gradle test runner anyway. Tests fake this interface; the
 * `android.telephony`-backed implementation lands behind it when the module
 * moves to AGP.
 *
 * Implementations emit the *current* state on each change. Duplicate
 * consecutive values are allowed - [CallTriggerMonitor] de-duplicates, so
 * an implementation that replays the state it registered with doesn't have
 * to care.
 */
interface CallStateSource {
    fun callStates(): Flow<PhoneCallState>
}
