package com.thrw.adapter.android.identity

/**
 * What a human typed into one of
 * [com.thrw.adapter.android.ui.ProvisioningActivity]'s two fields, either
 * normalized and safe to persist ([Valid]) or rejected with the reason why
 * ([Invalid]).
 */
sealed interface ProvisioningField {
    /** The normalized value to hand [AdapterProvisioning], not the raw text. */
    data class Valid(val value: String) : ProvisioningField

    data class Invalid(val problem: ProvisioningProblem) : ProvisioningField
}

/**
 * Why an entered value was rejected. The UI maps each of these to a
 * `strings.xml` message ([com.thrw.adapter.android.ui.ProvisioningActivity]);
 * this layer deliberately carries no user-facing strings so it stays free
 * of `android.*`.
 */
enum class ProvisioningProblem {
    BLANK,
    ACCOUNT_ID_TOO_LONG,
    ACCOUNT_ID_ILLEGAL_CHARACTERS,
    MALFORMED_BLUETOOTH_ADDRESS,
}

/**
 * Validation and normalization for the two values
 * [com.thrw.adapter.android.ui.ProvisioningActivity] collects, run before
 * [AdapterProvisioning] persists either of them.
 *
 * Pure Kotlin, no `android.*` imports - so it's unit-testable without
 * Robolectric or instrumentation, which this module has neither of. Same
 * seam discipline as [com.thrw.adapter.android.NodeRuntime] versus
 * [com.thrw.adapter.android.AdapterForegroundService]: the decidable logic
 * lives here and is tested, the `Activity` around it is a thin shell
 * (docs/handoffs/96.md, docs/handoffs/102.md).
 *
 * Neither format is defined anywhere authoritative yet - `services/licensing`
 * (which will eventually issue account ids) isn't built, and
 * `config/adapter.properties`'s `licensing.url` is still marked unused. So
 * these rules are derived from what the values are actually *used for*
 * downstream, not from a spec: see each function's kdoc.
 */
object ProvisioningInput {
    /**
     * Generous ceiling rather than a real limit: MQTT topic names are
     * capped at 65535 bytes, so this is only here to stop an absurd paste
     * from becoming a permanently broken topic prefix.
     */
    const val MAX_ACCOUNT_ID_LENGTH: Int = 128

    /**
     * Unreserved URL/topic characters only. Excludes `/`, `+` and `#`
     * because the account id is interpolated straight into every MQTT
     * topic ([com.thrw.adapter.android.protocol.Topics]) - a `/` would
     * silently reshape the frozen topic structure (ADR 0001) and a `+`/`#`
     * is a wildcard, which in a *subscribe* (commands, state) would make
     * this node listen across account boundaries. Also excludes
     * whitespace and anything non-ASCII, since the same string is the
     * broker's ACL key.
     */
    private val ACCOUNT_ID = Regex("^[A-Za-z0-9._:-]+$")

    /** Six colon-separated hex octets - `android.bluetooth`'s address form. */
    private val BLUETOOTH_ADDRESS = Regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")

    /**
     * Surrounding whitespace is trimmed (soft keyboards and paste both add
     * it readily); everything else must already be topic-safe per
     * [ACCOUNT_ID].
     */
    fun accountId(raw: String): ProvisioningField {
        val trimmed = raw.trim()
        return when {
            trimmed.isEmpty() -> ProvisioningField.Invalid(ProvisioningProblem.BLANK)
            trimmed.length > MAX_ACCOUNT_ID_LENGTH ->
                ProvisioningField.Invalid(ProvisioningProblem.ACCOUNT_ID_TOO_LONG)
            !ACCOUNT_ID.matches(trimmed) ->
                ProvisioningField.Invalid(ProvisioningProblem.ACCOUNT_ID_ILLEGAL_CHARACTERS)
            else -> ProvisioningField.Valid(trimmed)
        }
    }

    /**
     * Accepts either case but normalizes to upper case, because
     * `BluetoothAdapter.getRemoteDevice` - which
     * [com.thrw.adapter.android.bluetooth.AndroidBluetoothClassicGateway.connect]
     * calls with exactly this stored string - validates via
     * `BluetoothAdapter.checkBluetoothAddress`, and that requires upper-case
     * hex digits. A lower-case address typed here would otherwise persist
     * fine and then throw `IllegalArgumentException` on the first real
     * connect attempt, inside a foreground service with no UI to report it.
     *
     * Only the colon-separated form is accepted: it's the one form
     * `getRemoteDevice` takes, and the one Android's own Bluetooth settings
     * screens display.
     */
    fun headsetAddress(raw: String): ProvisioningField {
        val trimmed = raw.trim()
        return when {
            trimmed.isEmpty() -> ProvisioningField.Invalid(ProvisioningProblem.BLANK)
            !BLUETOOTH_ADDRESS.matches(trimmed) ->
                ProvisioningField.Invalid(ProvisioningProblem.MALFORMED_BLUETOOTH_ADDRESS)
            else -> ProvisioningField.Valid(trimmed.uppercase())
        }
    }
}
