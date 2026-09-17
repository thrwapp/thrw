package com.thrw.adapter.android.identity

import android.content.Context

/**
 * Which relay account this node belongs to, and which paired headset it
 * manages.
 *
 * Neither has a real home yet: there's no pairing/settings UI anywhere in
 * this codebase (out of scope for #96 - a composition root, not a UI
 * feature), and account association depends on `services/licensing` wiring
 * that also isn't built (`config/adapter.properties`'s own `licensing.url`
 * comment: "Unused until the licensing wiring issue lands"). This reads
 * persisted values a future settings/pairing screen would write, and is
 * deliberately the *only* thing standing in for that screen right now -
 * [com.thrw.adapter.android.AdapterForegroundService] treats both being
 * unset as "not provisioned yet" and refuses to start rather than
 * connecting a half-configured node. See docs/handoffs/96.md.
 */
object AdapterProvisioning {
    private const val PREFS_NAME = "thrw_adapter_provisioning"
    private const val KEY_ACCOUNT_ID = "account_id"
    private const val KEY_HEADSET_ADDRESS = "headset_address"

    fun accountId(context: Context): String? = prefs(context).getString(KEY_ACCOUNT_ID, null)

    fun headsetAddress(context: Context): String? = prefs(context).getString(KEY_HEADSET_ADDRESS, null)

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
