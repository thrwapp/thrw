@file:OptIn(ExperimentalCoroutinesApi::class)

package com.thrw.adapter.android.mqtt

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * ADR 0020's reconnect jitter, tested as a policy in isolation (#277).
 * [HiveMqttTransportTest] covers the half that matters at the transport
 * level: *which* of the two reconnect steps waits on it.
 *
 * Nothing here sleeps for real - [ReconnectJitter] takes its randomness
 * and its sleep as constructor parameters precisely so this file can
 * assert the wait without spending it.
 */
class ReconnectJitterTest {
    @Test
    fun `waits for exactly as long as the injected randomness draws`() = runTest {
        val slept = mutableListOf<Long>()
        val jitter = ReconnectJitter(random = ConstantRandom(1_234), sleep = { slept += it })

        jitter.await()

        assertEquals(listOf(1_234L), slept)
    }

    /**
     * The Mac's range is `Int.random(in: 0...2000)` - inclusive at both
     * ends. `Random.nextLong(until)` is exclusive of its bound, so the
     * bound has to be `max + 1` for the two adapters to draw from the
     * same set. Asserted on the bound itself because an off-by-one here
     * is invisible in any sampling test.
     */
    @Test
    fun `draws from zero to the maximum inclusive`() = runTest {
        val bounds = mutableListOf<Long>()
        val jitter = ReconnectJitter(
            maxMillis = 2_000,
            random = RecordingRandom(bounds),
            sleep = {},
        )

        jitter.await()

        assertEquals(listOf(2_001L), bounds)
    }

    @Test
    fun `every draw lands inside the window, and they are not all the same`() = runTest {
        val slept = mutableListOf<Long>()
        // Seeded, so a failure here is reproducible rather than a flake.
        val jitter = ReconnectJitter(random = Random(20_020), sleep = { slept += it })

        repeat(500) { jitter.await() }

        assertTrue(slept.all { it in 0..ReconnectJitter.DEFAULT_MAX_JITTER_MS }, "out of range: $slept")
        // A jitter that always returned the same number would satisfy
        // the bounds check above while spreading nothing at all, which
        // is the whole point of it.
        assertTrue(slept.distinct().size > 100, "barely varies: ${slept.distinct().size} distinct values")
    }

    @Test
    fun `the default sleep really suspends the caller`() = runTest {
        // No injected sleep: the real `delay`, measured on runTest's
        // virtual clock.
        val jitter = ReconnectJitter(random = ConstantRandom(1_500))

        val before = testScheduler.currentTime
        jitter.await()

        assertEquals(1_500L, testScheduler.currentTime - before)
    }

    /** Draws one fixed value, so the assertion can name it. */
    private class ConstantRandom(private val value: Long) : Random() {
        override fun nextBits(bitCount: Int): Int = throw UnsupportedOperationException()

        override fun nextLong(until: Long): Long = value
    }

    /** Records the exclusive bound it was asked for. */
    private class RecordingRandom(private val bounds: MutableList<Long>) : Random() {
        override fun nextBits(bitCount: Int): Int = throw UnsupportedOperationException()

        override fun nextLong(until: Long): Long {
            bounds += until
            return 0
        }
    }
}
