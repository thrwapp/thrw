package com.thrw.adapter.android.triggers

import android.annotation.SuppressLint
import android.content.Context
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import java.util.concurrent.Executor
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Real [CallStateSource], backed by `TelephonyManager.registerTelephonyCallback`
 * + `TelephonyCallback.CallStateListener` (API 31+) - the implementation
 * this interface's kdoc anticipated landing once the module moved to AGP
 * (#68 -> #96; see docs/handoffs/96.md).
 *
 * `READ_PHONE_STATE` (declared in `AndroidManifest.xml`) is required, and
 * like [com.thrw.adapter.android.bluetooth.AndroidBluetoothClassicGateway]
 * this class doesn't request it at runtime itself - no `Activity` exists
 * yet to host that dialog.
 *
 * Deliberately doesn't fall back to the deprecated `PhoneStateListener`
 * for pre-31 devices: `minSdk` is already 31 (see `app/build.gradle.kts`),
 * matching the reference hardware (Pixel 10 Pro, architecture.md).
 */
class AndroidCallStateSource(private val context: Context) : CallStateSource {
    @SuppressLint("MissingPermission")
    override fun callStates(): Flow<PhoneCallState> = callbackFlow {
        val telephonyManager = context.applicationContext.getSystemService(TelephonyManager::class.java)

        // No androidx dependency here to reach ContextCompat.getMainExecutor
        // (AGENTS.md: no new dependency without justification) - the
        // callback just forwards to trySend, which is thread-safe, so
        // running it on the calling thread rather than main is fine.
        val executor = Executor { command -> command.run() }
        val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
            override fun onCallStateChanged(state: Int) {
                trySend(state.toPhoneCallState())
            }
        }

        telephonyManager.registerTelephonyCallback(executor, callback)

        awaitClose { telephonyManager.unregisterTelephonyCallback(callback) }
    }

    private companion object {
        fun Int.toPhoneCallState(): PhoneCallState = when (this) {
            TelephonyManager.CALL_STATE_RINGING -> PhoneCallState.RINGING
            TelephonyManager.CALL_STATE_OFFHOOK -> PhoneCallState.OFFHOOK
            else -> PhoneCallState.IDLE
        }
    }
}
