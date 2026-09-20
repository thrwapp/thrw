package com.thrw.adapter.android.identity

import android.content.SharedPreferences

/**
 * An in-memory [SharedPreferences] for [AdapterProvisioningTest] and
 * [com.thrw.adapter.android.protocol.SharedPreferencesSequenceStoreTest].
 *
 * `SharedPreferences` is a plain interface, so unlike `Context` (an
 * abstract class whose every method is a stub returning null under
 * `isReturnDefaultValues = true`) it can be implemented honestly here -
 * which is why [AdapterProvisioning] exposes SharedPreferences-level
 * overloads for its getters and setters.
 *
 * Like the real thing, an [Editor]'s writes are buffered and only visible
 * once `apply()`/`commit()` is called - that's the behaviour the setter
 * tests rely on to prove the production code actually applies its edit.
 *
 * Only the string/contains surface [AdapterProvisioning] touches is
 * implemented; everything else is `TODO()` rather than a plausible-looking
 * stub, so a future caller reaching for it fails loudly instead of quietly
 * reading a zero.
 */
class FakeSharedPreferences : SharedPreferences {
    // `Any?` rather than `String?` since #210: the command sequence
    // store keeps a Long alongside its String epoch, and a fake that
    // could only hold strings would have forced the production store to
    // stringify a number purely to suit the test.
    private val values = mutableMapOf<String, Any?>()

    override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue

    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()

    override fun edit(): SharedPreferences.Editor = FakeEditor()

    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? = TODO()

    override fun getInt(key: String, defValue: Int): Int = TODO()

    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue

    override fun getFloat(key: String, defValue: Float): Float = TODO()

    override fun getBoolean(key: String, defValue: Boolean): Boolean = TODO()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = TODO()

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = TODO()

    private inner class FakeEditor : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()
        private val removed = mutableSetOf<String>()
        private var cleared = false

        // `also`, not `apply` - Editor has its own apply() member, and
        // reading `apply { ... }` here as the scope function takes a
        // second look.
        override fun putString(key: String, value: String?): SharedPreferences.Editor =
            also { pending[key] = value }

        override fun remove(key: String): SharedPreferences.Editor = also { removed += key }

        override fun clear(): SharedPreferences.Editor = also { cleared = true }

        override fun commit(): Boolean {
            if (cleared) values.clear()
            removed.forEach { values.remove(it) }
            values.putAll(pending)
            return true
        }

        override fun apply() {
            commit()
        }

        override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor = TODO()

        override fun putInt(key: String, value: Int): SharedPreferences.Editor = TODO()

        override fun putLong(key: String, value: Long): SharedPreferences.Editor =
            also { pending[key] = value }

        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = TODO()

        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = TODO()
    }
}
