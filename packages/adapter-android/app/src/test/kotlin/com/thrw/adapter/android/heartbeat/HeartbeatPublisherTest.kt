@file:OptIn(ExperimentalCoroutinesApi::class)

package com.thrw.adapter.android.heartbeat

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

private class RecordingHeartbeatSink : HeartbeatSink {
    var beats = 0
        private set

    override suspend fun publishHeartbeat() {
        beats++
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

    @Test
    fun `the default interval is the 30s architecture md specifies`() {
        // architecture.md's topic table: `heartbeat  QoS 0, ~30s`, and
        // relay-hosted's 90s timeout is 3x this. If this assertion is
        // ever "fixed" by changing the constant, change the relay's
        // timeout in the same PR - see HeartbeatPublisher's own kdoc.
        assertEquals(30_000L, HeartbeatPublisher.DEFAULT_INTERVAL_MS)
    }
}
