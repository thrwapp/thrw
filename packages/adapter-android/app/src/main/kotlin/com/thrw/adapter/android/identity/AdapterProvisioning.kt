package com.thrw.adapter.android.identity

import android.annotation.SuppressLint
import android.content.Context

/**
 * Which relay account this node belongs to, and which paired headset it
 * manages.
 *
 * Written by [com.thrw.adapter.android.ui.ProvisioningActivity] (#102, the
 * settings screen this object's kdoc previously said didn't exist) and read
 * by [com.thrw.adapter.android.AdapterForegroundService], which treats
 * either being unset as "not provisioned yet" and refuses to start rather
 * than connecting a half-configured node.
 *
 * Account association still doesn't come from anywhere authoritative -
 * `services/licensing` isn't built (`config/adapter.properties`'s own
 * `licensing.url` comment: "Unused until the licensing wiring issue lands"),
 * so the account id is typed in by hand for now rather than issued. See
 * docs/handoffs/96.md and docs/handoffs/102.md.
 *
 * Values are validated and normalized by [ProvisioningInput] before they
 * reach the setters here; this object persists strings, it doesn't police
 * their format.
 */
object AdapterProvisioning {
    private const val PREFS_NAME = "thrw_adapter_provisioning"
    private const val KEY_ACCOUNT_ID = "account_id"
    private const val KEY_HEADSET_ADDRESS = "headset_address"

    /**
     * The persistence seam. `SharedPreferences` is a framework interface
     * whose unit-test stub returns default values
     * (`testOptions.unitTests.isReturnDefaultValues`, see
     * `app/build.gradle.kts`), so the read/write logic below is only
     * testable against something substitutable - same discipline as the
     * `bluetooth`/`triggers` seams.
     *
     * [SharedPreferencesStore] is the real implementation; tests use an
     * in-memory fake.
     */
    interface Store {
        fun read(key: String): String?

        /** Writes every entry, durably, as one atomic commit. */
        fun write(values: Map<String, String>)
    }

    fun accountId(context: Context): String? = accountId(store(context))

    fun headsetAddress(context: Context): String? = headsetAddress(store(context))

    fun accountId(store: Store): String? = store.read(KEY_ACCOUNT_ID)

    fun headsetAddress(store: Store): String? = store.read(KEY_HEADSET_ADDRESS)

    fun setAccountId(context: Context, accountId: String) = setAccountId(store(context), accountId)

    fun setHeadsetAddress(context: Context, headsetAddress: String) =
        setHeadsetAddress(store(context), headsetAddress)

    fun setAccountId(store: Store, accountId: String) {
        store.write(mapOf(KEY_ACCOUNT_ID to accountId))
    }

    fun setHeadsetAddress(store: Store, headsetAddress: String) {
        store.write(mapOf(KEY_HEADSET_ADDRESS to headsetAddress))
    }

    /**
     * Both setters in a single write, which is what the settings screen
     * uses: [com.thrw.adapter.android.AdapterForegroundService] reads the
     * pair together on every start, so committing them separately leaves a
     * window where a start would see a new account id against the old
     * headset address.
     */
    fun save(context: Context, accountId: String, headsetAddress: String) =
        save(store(context), accountId, headsetAddress)

    fun save(store: Store, accountId: String, headsetAddress: String) {
        store.write(
            mapOf(
                KEY_ACCOUNT_ID to accountId,
                KEY_HEADSET_ADDRESS to headsetAddress,
            ),
        )
    }

    fun store(context: Context): Store = SharedPreferencesStore(context)

    /**
     * The real [Store]: the same [PREFS_NAME] `SharedPreferences` file the
     * getters have always read.
     *
     * Uses `commit()` rather than `apply()` on purpose - the expected next
     * step after saving provisioning is a reboot (see
     * [com.thrw.adapter.android.BootCompletedReceiver], the service's start
     * path), and `apply()` only guarantees the in-memory value, not that
     * the write reached disk first. A two-key write on a button press is a
     * cheap enough blocking I/O to accept for that guarantee.
     */
    private class SharedPreferencesStore(context: Context) : Store {
        private val prefs =
            context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        override fun read(key: String): String? = prefs.getString(key, null)

        // Lint's ApplySharedPref check prefers apply(); the blocking write
        // is the point here (see this class's kdoc), so it's suppressed
        // deliberately rather than left as a standing warning.
        @SuppressLint("ApplySharedPref")
        override fun write(values: Map<String, String>) {
            val editor = prefs.edit()
            values.forEach { (key, value) -> editor.putString(key, value) }
            editor.commit()
        }
    }
}
