package com.thrw.adapter.android.identity

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Covers the [AdapterProvisioning] setters added in #102 against a fake
 * [android.content.SharedPreferences] ([FakeSharedPreferences]).
 *
 * What this cannot cover: the `Context` overloads, which only add
 * `getSharedPreferences(PREFS_NAME, MODE_PRIVATE)` on top of what's tested
 * here - `Context` is stubbed to nulls in unit tests (`isReturnDefaultValues`),
 * and Robolectric isn't a dependency of this module. The keys and prefs
 * file name are therefore asserted indirectly: these tests write with the
 * setters and read back with the getters
 * [com.thrw.adapter.android.AdapterForegroundService] itself calls, so a
 * setter writing a key the service doesn't read would fail here.
 */
class AdapterProvisioningTest {
    @Test
    fun `an unprovisioned device reads back null for both values`() {
        val prefs = FakeSharedPreferences()

        assertNull(AdapterProvisioning.accountId(prefs))
        assertNull(AdapterProvisioning.headsetAddress(prefs))
    }

    @Test
    fun `each setter round-trips through the key its getter reads`() {
        val prefs = FakeSharedPreferences()

        AdapterProvisioning.setAccountId(prefs, "tom-personal")
        AdapterProvisioning.setHeadsetAddress(prefs, "AA:BB:CC:DD:EE:FF")

        assertEquals("tom-personal", AdapterProvisioning.accountId(prefs))
        assertEquals("AA:BB:CC:DD:EE:FF", AdapterProvisioning.headsetAddress(prefs))
    }

    @Test
    fun `setting one value leaves the other alone`() {
        val prefs = FakeSharedPreferences()
        AdapterProvisioning.setAccountId(prefs, "tom-personal")
        AdapterProvisioning.setHeadsetAddress(prefs, "AA:BB:CC:DD:EE:FF")

        AdapterProvisioning.setHeadsetAddress(prefs, "00:1A:7D:DA:71:13")

        assertEquals("tom-personal", AdapterProvisioning.accountId(prefs))
        assertEquals("00:1A:7D:DA:71:13", AdapterProvisioning.headsetAddress(prefs))
    }

    /**
     * The setters persist whatever they're handed - validation lives in
     * [ProvisioningInput] and is the caller's job (see
     * [com.thrw.adapter.android.ui.ProvisioningActivity], which validates
     * before saving). Pinned so that contract is a decision, not an
     * accident.
     */
    @Test
    fun `the setters do not validate - that is the callers job`() {
        val prefs = FakeSharedPreferences()

        AdapterProvisioning.setAccountId(prefs, "not/topic/safe")

        assertEquals("not/topic/safe", AdapterProvisioning.accountId(prefs))
    }
}
