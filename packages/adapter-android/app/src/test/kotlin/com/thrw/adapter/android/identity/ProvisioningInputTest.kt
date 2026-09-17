package com.thrw.adapter.android.identity

import kotlin.test.Test
import kotlin.test.assertEquals

class ProvisioningInputTest {
    private fun validValue(result: FieldResult): String =
        (result as? FieldResult.Valid)?.value ?: error("expected Valid, got $result")

    private fun errorOf(result: FieldResult): FieldError =
        (result as? FieldResult.Invalid)?.error ?: error("expected Invalid, got $result")

    @Test
    fun `an account id is kept as typed, minus surrounding whitespace`() {
        assertEquals("tom-personal", validValue(ProvisioningInput.accountId("  tom-personal  ")))
        assertEquals("acct.123_x", validValue(ProvisioningInput.accountId("acct.123_x")))
    }

    @Test
    fun `an empty or whitespace-only account id is rejected`() {
        assertEquals(FieldError.ACCOUNT_ID_BLANK, errorOf(ProvisioningInput.accountId("")))
        assertEquals(FieldError.ACCOUNT_ID_BLANK, errorOf(ProvisioningInput.accountId("   ")))
    }

    /**
     * The account id is interpolated straight into every MQTT topic
     * (`thrw/{account}/...`, see [com.thrw.adapter.android.protocol.Topics]) -
     * a `/` would silently add a topic level and `+`/`#` are wildcards,
     * so none of them can be allowed to reach the broker.
     */
    @Test
    fun `account ids that would corrupt an MQTT topic are rejected`() {
        for (raw in listOf("tom/personal", "tom+personal", "tom#", "tom personal", "tøm")) {
            assertEquals(FieldError.ACCOUNT_ID_UNSUPPORTED_CHARACTERS, errorOf(ProvisioningInput.accountId(raw)), raw)
        }
    }

    @Test
    fun `an over-long account id is rejected`() {
        assertEquals("a".repeat(64), validValue(ProvisioningInput.accountId("a".repeat(64))))
        assertEquals(
            FieldError.ACCOUNT_ID_UNSUPPORTED_CHARACTERS,
            errorOf(ProvisioningInput.accountId("a".repeat(65))),
        )
    }

    @Test
    fun `a headset address is normalized to the upper-case form the Bluetooth stack wants`() {
        assertEquals("AA:BB:CC:DD:EE:FF", validValue(ProvisioningInput.headsetAddress("aa:bb:cc:dd:ee:ff")))
        assertEquals("00:1A:7D:DA:71:13", validValue(ProvisioningInput.headsetAddress(" 00:1a:7D:da:71:13 ")))
    }

    @Test
    fun `an empty headset address is rejected`() {
        assertEquals(FieldError.HEADSET_ADDRESS_BLANK, errorOf(ProvisioningInput.headsetAddress("   ")))
    }

    /**
     * `BluetoothAdapter.getRemoteDevice` throws `IllegalArgumentException`
     * on anything but six colon-separated hex octets - and it would throw
     * inside [com.thrw.adapter.android.AdapterForegroundService]'s
     * coroutine, long after this screen is gone, so it's caught here.
     */
    @Test
    fun `malformed headset addresses are rejected`() {
        for (raw in listOf(
            "AA:BB:CC:DD:EE",
            "AA:BB:CC:DD:EE:FF:00",
            "AA-BB-CC-DD-EE-FF",
            "AABBCCDDEEFF",
            "ZZ:BB:CC:DD:EE:FF",
            "A:BB:CC:DD:EE:FF",
            "AA:BB:CC:DD:EE:FF ext",
        )) {
            assertEquals(FieldError.HEADSET_ADDRESS_MALFORMED, errorOf(ProvisioningInput.headsetAddress(raw)), raw)
        }
    }
}
