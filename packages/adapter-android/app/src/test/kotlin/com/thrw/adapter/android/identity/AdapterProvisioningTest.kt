package com.thrw.adapter.android.identity

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Covers [AdapterProvisioning]'s read/write logic against a fake
 * [AdapterProvisioning.Store]. The real, `SharedPreferences`-backed store is
 * *not* covered: `SharedPreferences` is a framework interface whose unit-test
 * stub returns default values (`testOptions.unitTests.isReturnDefaultValues`
 * in app/build.gradle.kts), so exercising it needs Robolectric or
 * instrumentation - neither of which this module has. See docs/handoffs/102.md.
 */
class AdapterProvisioningTest {
    /** In-memory [AdapterProvisioning.Store], recording each write as one batch. */
    private class FakeStore : AdapterProvisioning.Store {
        val values = mutableMapOf<String, String>()
        val writes = mutableListOf<Map<String, String>>()

        override fun read(key: String): String? = values[key]

        override fun write(values: Map<String, String>) {
            writes += values
            this.values.putAll(values)
        }
    }

    @Test
    fun `an unprovisioned store reads back as null, which the service treats as not provisioned`() {
        val store = FakeStore()

        assertNull(AdapterProvisioning.accountId(store))
        assertNull(AdapterProvisioning.headsetAddress(store))
    }

    @Test
    fun `each setter round-trips through its own key`() {
        val store = FakeStore()

        AdapterProvisioning.setAccountId(store, "acct-1")
        AdapterProvisioning.setHeadsetAddress(store, "AA:BB:CC:DD:EE:FF")

        assertEquals("acct-1", AdapterProvisioning.accountId(store))
        assertEquals("AA:BB:CC:DD:EE:FF", AdapterProvisioning.headsetAddress(store))
    }

    /**
     * The two keys must land in the same commit: `AdapterForegroundService`
     * reads the pair together on every `onStartCommand`, so two separate
     * writes would leave a window where a start sees a new account id
     * against the previous headset address.
     */
    @Test
    fun `save writes both keys in a single commit`() {
        val store = FakeStore()

        AdapterProvisioning.save(store, "acct-1", "AA:BB:CC:DD:EE:FF")

        assertEquals(1, store.writes.size)
        assertEquals(
            mapOf("account_id" to "acct-1", "headset_address" to "AA:BB:CC:DD:EE:FF"),
            store.writes.single(),
        )
    }

    /** Re-provisioning to a different account/headset overwrites, not appends. */
    @Test
    fun `saving again replaces the previous values`() {
        val store = FakeStore()

        AdapterProvisioning.save(store, "acct-1", "AA:BB:CC:DD:EE:FF")
        AdapterProvisioning.save(store, "acct-2", "11:22:33:44:55:66")

        assertEquals("acct-2", AdapterProvisioning.accountId(store))
        assertEquals("11:22:33:44:55:66", AdapterProvisioning.headsetAddress(store))
    }

    /**
     * The keys written here are the exact ones
     * [com.thrw.adapter.android.AdapterForegroundService] already read
     * before this change (#102's acceptance criterion 1: don't invent new
     * keys). Asserted by literal string rather than by referring to
     * `AdapterProvisioning`'s own private constants, so a rename that broke
     * the service's reads would fail this test.
     */
    @Test
    fun `the persisted keys are the ones the service already reads`() {
        val store = FakeStore()

        AdapterProvisioning.save(store, "acct-1", "AA:BB:CC:DD:EE:FF")

        assertEquals("acct-1", store.values["account_id"])
        assertEquals("AA:BB:CC:DD:EE:FF", store.values["headset_address"])
    }

    /** The end-to-end path the save button takes: validate, then persist. */
    @Test
    fun `validated input is what reaches the store`() {
        val store = FakeStore()
        val accountId = ProvisioningInput.accountId(" acct-1 ")
        val headsetAddress = ProvisioningInput.headsetAddress("aa:bb:cc:dd:ee:ff")

        AdapterProvisioning.save(
            store,
            (accountId as ProvisioningField.Valid).value,
            (headsetAddress as ProvisioningField.Valid).value,
        )

        assertEquals("acct-1", AdapterProvisioning.accountId(store))
        assertEquals("AA:BB:CC:DD:EE:FF", AdapterProvisioning.headsetAddress(store))
    }
}
