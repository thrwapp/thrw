package com.thrw.adapter.android.bluetooth

/**
 * Why a gateway call failed, in the two categories ADR 0019's reason
 * codes actually distinguish (#264).
 *
 * Before this, every gateway failure was an `IllegalStateException` and
 * `AndroidNode` flattened all of them to `target_device_unreachable`.
 * That is wrong for half of them: a missing profile proxy or a blocked
 * hidden API is a problem with *this device*, not with the headset, and
 * recording it as "the headset did not answer" sends anyone reading the
 * telemetry to look at the wrong end of the link.
 *
 * Kotlin mirror of `adapter-mac`'s `BluetoothGatewayError` cases, which
 * map to the same two reason codes - #264's criterion 4 asks that an
 * outcome mean the same thing in every row, whichever adapter produced
 * it.
 */
sealed class BluetoothGatewayException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {

    /**
     * The headset did not answer: off, in its case, out of range, or it
     * accepted the request and then dropped it.
     *
     * Maps to `target_device_unreachable`.
     */
    class HeadsetUnreachable(message: String) : BluetoothGatewayException(message)

    /**
     * The local Bluetooth stack could not be driven at all - no usable
     * profile proxy, a revoked permission, or a hidden API this Android
     * version has blocked (#162).
     *
     * Maps to `bluetooth_unavailable`. Nothing was ever asked of the
     * headset, so blaming it would be a fabrication.
     */
    class BluetoothUnavailable(message: String, cause: Throwable? = null) :
        BluetoothGatewayException(message, cause)
}
