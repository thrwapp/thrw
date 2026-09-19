package com.thrw.adapter.android.triggers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SelfCooldownTest {
    private class FakeClock(var millis: Long = 0) : () -> Long {
        override fun invoke(): Long = millis
    }

    @Test
    fun `inactive before anything is armed`() {
        assertFalse(SelfCooldown(now = FakeClock()).isActive())
    }

    @Test
    fun `active immediately after arming`() {
        val clock = FakeClock()
        val cooldown = SelfCooldown(windowMs = 3_000, now = clock)

        cooldown.arm()

        assertTrue(cooldown.isActive())
    }

    @Test
    fun `still active just inside the window`() {
        val clock = FakeClock()
        val cooldown = SelfCooldown(windowMs = 3_000, now = clock)
        cooldown.arm()

        clock.millis = 2_999

        assertTrue(cooldown.isActive())
    }

    @Test
    fun `inactive once the window has elapsed`() {
        val clock = FakeClock()
        val cooldown = SelfCooldown(windowMs = 3_000, now = clock)
        cooldown.arm()

        clock.millis = 3_000

        assertFalse(cooldown.isActive())
    }

    /** A second claim/release extends the window from that moment. */
    @Test
    fun `re-arming restarts the window`() {
        val clock = FakeClock()
        val cooldown = SelfCooldown(windowMs = 3_000, now = clock)
        cooldown.arm()

        clock.millis = 2_500
        cooldown.arm()
        clock.millis = 4_000

        assertTrue(cooldown.isActive(), "re-arming at 2500 should extend to 5500")
    }

    @Test
    fun `the default window is the 3 seconds ADR 0010 specifies`() {
        assertEquals(3_000L, SelfCooldown.DEFAULT_WINDOW_MS)
    }
}
