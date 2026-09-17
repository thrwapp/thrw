package com.thrw.adapter.android.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NotificationAccessTest {
    @Test
    fun `granted when this app's package is in the enabled-listeners set`() {
        assertTrue(
            NotificationAccess.isGranted(
                packageName = "com.thrw.adapter.android",
                enabledListenerPackages = setOf("com.thrw.adapter.android"),
            ),
        )
    }

    @Test
    fun `not granted when the enabled-listeners set is empty`() {
        assertFalse(
            NotificationAccess.isGranted(
                packageName = "com.thrw.adapter.android",
                enabledListenerPackages = emptySet(),
            ),
        )
    }

    @Test
    fun `not granted when only other packages are in the enabled-listeners set`() {
        assertFalse(
            NotificationAccess.isGranted(
                packageName = "com.thrw.adapter.android",
                enabledListenerPackages = setOf("com.some.other.app", "com.another.app"),
            ),
        )
    }

    @Test
    fun `granted when this app's package is among several enabled listeners`() {
        assertTrue(
            NotificationAccess.isGranted(
                packageName = "com.thrw.adapter.android",
                enabledListenerPackages = setOf("com.some.other.app", "com.thrw.adapter.android"),
            ),
        )
    }

    @Test
    fun `flattenedComponentName joins package and class with a slash`() {
        assertEquals(
            "com.thrw.adapter.android/com.thrw.adapter.android.triggers.AndroidNotificationListenerService",
            NotificationAccess.flattenedComponentName(
                packageName = "com.thrw.adapter.android",
                className = "com.thrw.adapter.android.triggers.AndroidNotificationListenerService",
            ),
        )
    }
}
