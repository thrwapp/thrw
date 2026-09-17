package com.thrw.adapter.android.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AdapterPermissionsTest {
    /**
     * `POST_NOTIFICATIONS` doesn't exist below API 33, and this module's
     * `minSdk` is 31 - requesting it on a 31/32 device comes back denied
     * for a permission the user was never actually asked about.
     */
    @Test
    fun `POST_NOTIFICATIONS is only requested on API 33 and up`() {
        assertEquals(
            listOf(AdapterPermissions.BLUETOOTH_CONNECT, AdapterPermissions.READ_PHONE_STATE),
            AdapterPermissions.requestable(sdkInt = 32),
        )
        assertEquals(
            listOf(
                AdapterPermissions.BLUETOOTH_CONNECT,
                AdapterPermissions.READ_PHONE_STATE,
                AdapterPermissions.POST_NOTIFICATIONS,
            ),
            AdapterPermissions.requestable(sdkInt = 33),
        )
    }

    /** The three permissions AndroidManifest.xml declares as dangerous. */
    @Test
    fun `the requested permissions are the manifests own dangerous ones`() {
        assertEquals(
            listOf(
                "android.permission.BLUETOOTH_CONNECT",
                "android.permission.READ_PHONE_STATE",
                "android.permission.POST_NOTIFICATIONS",
            ),
            AdapterPermissions.requestable(sdkInt = 35),
        )
    }

    @Test
    fun `missing lists only the permissions not already granted`() {
        val granted = setOf(AdapterPermissions.BLUETOOTH_CONNECT)

        val missing = AdapterPermissions.missing(sdkInt = 35) { it in granted }

        assertEquals(
            listOf(AdapterPermissions.READ_PHONE_STATE, AdapterPermissions.POST_NOTIFICATIONS),
            missing,
        )
    }

    @Test
    fun `nothing is missing once every permission is granted`() {
        assertTrue(AdapterPermissions.missing(sdkInt = 35) { true }.isEmpty())
        assertFalse(AdapterPermissions.missing(sdkInt = 35) { false }.isEmpty())
    }
}
