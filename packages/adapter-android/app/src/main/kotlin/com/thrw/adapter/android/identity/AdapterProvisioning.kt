package com.thrw.adapter.android.identity

import android.content.Context
import android.content.SharedPreferences

/**
 * Which relay account this node belongs to, and which paired headset it
 * manages.
 *
 * Read by [com.thrw.adapter.android.AdapterForegroundService], which treats
 * either being unset as "not provisioned yet" and refuses to start rather
 * than connecting a half-configured node. Written by
 * [com.thrw.adapter.android.ui.ProvisioningActivity] (#102) - before that
 * landed there was no way to set either value short of `adb shell`, which
 * is what this class's previous kdoc meant by "neither has a real home
 * yet". Account association still doesn't involve `services/licensing`
 * (not built yet - see `config/adapter.properties`'s `licensing.url`
 * comment); the account id is whatever the user types in.
 *
 * The setters take the values already validated/normalized by
 * [ProvisioningInput] - this object persists what it's given and doesn't
 * re-check it, so callers other than the activity must validate too.
 *
 * Each setter is its own `apply()`, so saving both fields is two separate
 * atomic writes rather than one. That's fine here: the service reads the
 * pair exactly once, in `onStartCommand`, and nothing re-reads it while
 * running - so the only way to observe a half-updated pair is to start the
 * service in the microseconds between the two writes, and the activity
 * deliberately doesn't start the service at all (see
 * [com.thrw.adapter.android.ui.ProvisioningActivity]'s kdoc).
 */
object AdapterProvisioning {
    private const val PREFS_NAME = "thrw_adapter_provisioning"
    private const val KEY_ACCOUNT_ID = "account_id"
    private const val KEY_HEADSET_ADDRESS = "headset_address"

    fun accountId(context: Context): String? = accountId(prefs(context))

    fun headsetAddress(context: Context): String? = headsetAddress(prefs(context))

    fun setAccountId(context: Context, accountId: String) = setAccountId(prefs(context), accountId)

    fun setHeadsetAddress(context: Context, headsetAddress: String) =
        setHeadsetAddress(prefs(context), headsetAddress)

    // The four overloads below are the same logic against the
    // SharedPreferences seam directly, without a Context. Unit tests here
    // run on a stubbed android.jar (`isReturnDefaultValues = true`, see
    // app/build.gradle.kts), where a real Context hands back nothing
    // usable - but SharedPreferences is a plain interface, so a fake
    // implementation of it can exercise these for real. See
    // AdapterProvisioningTest.
    internal fun accountId(prefs: SharedPreferences): String? = prefs.getString(KEY_ACCOUNT_ID, null)

    internal fun headsetAddress(prefs: SharedPreferences): String? = prefs.getString(KEY_HEADSET_ADDRESS, null)

    internal fun setAccountId(prefs: SharedPreferences, accountId: String) {
        prefs.edit().putString(KEY_ACCOUNT_ID, accountId).apply()
    }

    internal fun setHeadsetAddress(prefs: SharedPreferences, headsetAddress: String) {
        prefs.edit().putString(KEY_HEADSET_ADDRESS, headsetAddress).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
