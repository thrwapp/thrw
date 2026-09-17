package com.thrw.adapter.android.ui

import android.Manifest
import android.os.Build

/**
 * The runtime-dangerous permissions declared in `AndroidManifest.xml` that
 * the adapter actually needs granted, and which of them are requestable on
 * the running OS version.
 *
 * Pure logic (the only `android.*` references are the permission-name and
 * version constants, both compile-time `String`/`Int` values that resolve
 * fine under unit tests) so the version gate below is testable without an
 * emulator - see AdapterPermissionsTest.
 */
object AdapterPermissions {
    /**
     * Connect/disconnect the bonded headset - `BLUETOOTH_CONNECT` is
     * required by every call in
     * [com.thrw.adapter.android.bluetooth.AndroidBluetoothClassicGateway].
     */
    const val BLUETOOTH_CONNECT: String = Manifest.permission.BLUETOOTH_CONNECT

    /**
     * Phone call state for
     * [com.thrw.adapter.android.triggers.AndroidCallStateSource]'s
     * `TelephonyCallback` registration (architecture.md priority rule 1).
     */
    const val READ_PHONE_STATE: String = Manifest.permission.READ_PHONE_STATE

    /**
     * [com.thrw.adapter.android.AdapterForegroundService]'s own persistent
     * notification. API 33+ only - see [requestable].
     */
    const val POST_NOTIFICATIONS: String = Manifest.permission.POST_NOTIFICATIONS

    /**
     * The permissions worth asking for on an OS at API level [sdkInt].
     *
     * `POST_NOTIFICATIONS` didn't exist before API 33 (Tiramisu) and this
     * module's `minSdk` is 31, so on a 31/32 device requesting it would
     * come back permanently "denied" - not because the user said no, but
     * because the platform doesn't know the permission - and the screen
     * would nag about a permission that is implicitly granted there. So
     * it's filtered out below rather than requested and misreported.
     */
    fun requestable(sdkInt: Int = Build.VERSION.SDK_INT): List<String> = buildList {
        add(BLUETOOTH_CONNECT)
        add(READ_PHONE_STATE)
        if (sdkInt >= Build.VERSION_CODES.TIRAMISU) add(POST_NOTIFICATIONS)
    }

    /**
     * Of [requestable], the ones not yet granted. [isGranted] is the
     * caller's `Context.checkSelfPermission(...) == PERMISSION_GRANTED`,
     * injected so this stays testable.
     */
    fun missing(sdkInt: Int = Build.VERSION.SDK_INT, isGranted: (String) -> Boolean): List<String> =
        requestable(sdkInt).filterNot(isGranted)
}
