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

    /**
     * #251. Was 3 seconds; ADR 0010's 2026-09-23 amendment makes it 6.
     *
     * The original *estimated* ~3s for thrw's own side effect to play
     * out. ADR 0018 later *measured* a claim taking 3-5s to move the
     * route, so the window closed before the transition it exists to
     * cover had finished - and on hardware the tail of that transition
     * read as a fresh `media` trigger, bouncing the headset between
     * devices indefinitely.
     *
     * `adapter-mac`'s `defaultSelfCooldown` is the same number on the
     * other side of the same behaviour.
     */
    @Test
    fun `the default window is the 6 seconds ADR 0010 specifies`() {
        assertEquals(6_000L, SelfCooldown.DEFAULT_WINDOW_MS)
    }
}
