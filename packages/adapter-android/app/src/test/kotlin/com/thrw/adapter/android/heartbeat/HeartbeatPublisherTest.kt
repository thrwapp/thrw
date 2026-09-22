@file:OptIn(ExperimentalCoroutinesApi::class)

package com.thrw.adapter.android.heartbeat

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

private class RecordingHeartbeatSink(
    /** #236 - the 1-based beat number that should throw, if any. */
    private val failOnBeat: Int? = null,
    /** #236 - the beat that should throw [CancellationException] instead. */
    private val cancelOnBeat: Int? = null,
) : HeartbeatSink {
    var beats = 0
        private set

    class Boom : RuntimeException("publish failed")

    override suspend fun publishHeartbeat() {
        beats++
        if (beats == cancelOnBeat) throw CancellationException("cancelled mid-publish")
        if (beats == failOnBeat) throw Boom()
    }
}

/**
 * `runTest`'s virtual clock means these assert the real interval without
 * waiting on wall time - the Kotlin equivalent of `adapter-mac`'s
 * injectable `sleep` in `HeartbeatPublisherTests.swift`.
 */
class HeartbeatPublisherTest {
    @Test
    fun `beats immediately rather than waiting out the first interval`() = runTest {
        val sink = RecordingHeartbeatSink()
        val job = launch { HeartbeatPublisher(sink, intervalMs = 30_000).run() }

        // Lets the coroutine reach its first suspension point (the delay)
        // without advancing the clock - `launch` only schedules it.
        runCurrent()

        // Still zero virtual time elapsed, yet the beat is already out.
        assertEquals(0L, testScheduler.currentTime)
        assertEquals(1, sink.beats)

        job.cancelAndJoin()
    }

    @Test
    fun `beats once per interval`() = runTest {
        val sink = RecordingHeartbeatSink()
        val job = launch { HeartbeatPublisher(sink, intervalMs = 30_000).run() }

        advanceTimeBy(30_001)
        assertEquals(2, sink.beats)

        advanceTimeBy(30_000)
        assertEquals(3, sink.beats)

        job.cancelAndJoin()
    }

    @Test
    fun `does not beat again before a full interval has elapsed`() = runTest {
        val sink = RecordingHeartbeatSink()
        val job = launch { HeartbeatPublisher(sink, intervalMs = 30_000).run() }

        advanceTimeBy(29_999)
        assertEquals(1, sink.beats)

        job.cancelAndJoin()
    }

    @Test
    fun `stops beating once cancelled`() = runTest {
        val sink = RecordingHeartbeatSink()
        val job = launch { HeartbeatPublisher(sink, intervalMs = 30_000).run() }

        advanceTimeBy(30_001)
        val beatsAtCancel = sink.beats
        job.cancelAndJoin()

        advanceTimeBy(300_000)
        assertEquals(beatsAtCancel, sink.beats)
    }

    /**
     * #236. Mirrors `adapter-mac`'s
     * `testAFailedBeatDoesNotEndTheLoop`.
     *
     * A bare `sink.publishHeartbeat()` in the loop body meant one throw
     * ended it permanently - `NodeRuntime` logs it and nothing restarts
     * it. The node then registers every 120s without ever beating, the
     * relay reaps it 90s after each registration, and the headset
     * ping-pongs indefinitely. Nine and a half hours of that was observed
     * in production.
     */
    @Test
    fun `a failed beat does not end the loop`() = runTest {
        val sink = RecordingHeartbeatSink(failOnBeat = 1)
        val job = launch { HeartbeatPublisher(sink, intervalMs = 30_000).run() }

        runCurrent()
        assertEquals(1, sink.beats, "the failing beat was still attempted")

        // Before #236 the loop was gone by now and these were no-ops.
        advanceTimeBy(30_001)
        assertEquals(2, sink.beats, "expected beating to resume after a failure")
        advanceTimeBy(30_000)
        assertEquals(3, sink.beats)
        assertTrue(job.isActive, "the loop must still be running")

        job.cancelAndJoin()
    }

    /**
     * The other half: cancellation must still stop the loop, or nothing
     * can, and every ordinary service shutdown logs an error.
     */
    @Test
    fun `cancellation from a publish still stops the loop`() = runTest {
        val sink = RecordingHeartbeatSink(cancelOnBeat = 1)
        val job = launch { HeartbeatPublisher(sink, intervalMs = 30_000).run() }

        runCurrent()
        assertEquals(1, sink.beats)
        assertTrue(job.isCancelled, "CancellationException must not be caught as a publish failure")

        advanceTimeBy(300_000)
        assertEquals(1, sink.beats, "expected no further beats after cancellation")
    }

    @Test
    fun `the default interval is the 30s architecture md specifies`() {
        // architecture.md's topic table: `heartbeat  QoS 0, ~30s`, and
        // relay-hosted's 90s timeout is 3x this. If this assertion is
        // ever "fixed" by changing the constant, change the relay's
        // timeout in the same PR - see HeartbeatPublisher's own kdoc.
        assertEquals(30_000L, HeartbeatPublisher.DEFAULT_INTERVAL_MS)
    }
}
