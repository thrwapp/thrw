package com.thrw.adapter.android.identity

import java.util.Locale

/**
 * Validation + normalization of what a human types into the provisioning
 * screen ([com.thrw.adapter.android.ui.ProvisioningActivity]), kept as pure
 * Kotlin with no `android.*` imports so it can actually be unit tested -
 * the `Activity` around it can't be, without Robolectric/instrumentation
 * (neither is in this codebase; see docs/handoffs/102.md).
 *
 * Validating at all - rather than persisting the raw strings - matters
 * because both values are read by a headless foreground service that has
 * no way to report a typo back to the user: a stray space in the account
 * id silently produces a topic nobody is subscribed to, and a malformed
 * headset address makes `BluetoothAdapter.getRemoteDevice` throw inside
 * the service's coroutine long after the screen is gone.
 */
object ProvisioningInput {
    /**
     * Account ids are topic-safe ASCII: letters, digits, `.`, `_`, `-`,
     * up to 64 characters.
     *
     * There is no canonical account-id format defined anywhere in this
     * repo yet (`services/licensing`, which will mint them, isn't built -
     * ADR 0005's `licensing.url` is still unused), so this deliberately
     * checks only what the protocol itself requires rather than inventing
     * a shape the licensing service might contradict later: the value is
     * interpolated straight into every MQTT topic
     * (`thrw/{account}/...`, see [com.thrw.adapter.android.protocol.Topics]
     * and architecture.md's "MQTT topic design"), so `/`, the `+`/`#`
     * wildcards, whitespace and non-ASCII are rejected.
     */
    private val ACCOUNT_ID = Regex("^[A-Za-z0-9._-]{1,64}$")

    /**
     * The exact shape `BluetoothAdapter.getRemoteDevice` accepts:
     * six colon-separated uppercase hex octets.
     *
     * Checked with a regex rather than via `BluetoothAdapter`'s own
     * `checkBluetoothAddress` helper for two reasons: that's a framework
     * call, so it returns a stubbed `false` under this module's unit tests
     * (`isReturnDefaultValues = true`), and it rejects lowercase outright
     * where this normalizes it instead - a headset MAC copied out of
     * Android's own Bluetooth settings is frequently lowercase.
     */
    private val HEADSET_ADDRESS = Regex("^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")

    /** Validates a typed account id, trimming surrounding whitespace. */
    fun accountId(raw: String): FieldResult {
        val trimmed = raw.trim()
        return when {
            trimmed.isEmpty() -> FieldResult.Invalid(FieldError.ACCOUNT_ID_BLANK)
            !ACCOUNT_ID.matches(trimmed) -> FieldResult.Invalid(FieldError.ACCOUNT_ID_UNSUPPORTED_CHARACTERS)
            else -> FieldResult.Valid(trimmed)
        }
    }

    /**
     * Validates a typed headset Bluetooth address, trimming surrounding
     * whitespace and upper-casing it to the form the Bluetooth stack
     * wants.
     */
    fun headsetAddress(raw: String): FieldResult {
        val normalized = raw.trim().uppercase(Locale.ROOT)
        return when {
            normalized.isEmpty() -> FieldResult.Invalid(FieldError.HEADSET_ADDRESS_BLANK)
            !HEADSET_ADDRESS.matches(normalized) -> FieldResult.Invalid(FieldError.HEADSET_ADDRESS_MALFORMED)
            else -> FieldResult.Valid(normalized)
        }
    }
}

/** Outcome of validating one provisioning field. */
sealed interface FieldResult {
    /** The normalized value to persist - not necessarily what was typed. */
    data class Valid(val value: String) : FieldResult

    data class Invalid(val error: FieldError) : FieldResult
}

/**
 * Why a field was rejected. An enum rather than a message string so this
 * stays free of `android.*`/`R` references - the activity maps each case
 * to a `strings.xml` message.
 */
enum class FieldError {
    ACCOUNT_ID_BLANK,
    ACCOUNT_ID_UNSUPPORTED_CHARACTERS,
    HEADSET_ADDRESS_BLANK,
    HEADSET_ADDRESS_MALFORMED,
}
