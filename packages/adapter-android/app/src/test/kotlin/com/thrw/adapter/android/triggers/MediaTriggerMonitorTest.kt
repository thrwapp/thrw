package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.test.runTest

private fun playing(key: String) = MediaSessionEvent.Changed(MediaSessionState(key, isPlaying = true))
private fun paused(key: String) = MediaSessionEvent.Changed(MediaSessionState(key, isPlaying = false))

private class FakeMediaSessionSource(private val events: List<MediaSessionEvent>) : MediaSessionSource {
    override fun sessions(): Flow<MediaSessionEvent> = events.asFlow()
}

class MediaTriggerMonitorTest {
    @Test
    fun `playback starting emits media`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(FakeMediaSessionSource(listOf(playing("com.spotify.music"))), node).run()

        assertEquals(listOf<TriggerCall>(TriggerCall.Started(EventKind.MEDIA, UNRANKED_PRIORITY)), node.calls)
    }

    @Test
    fun `playback stopping ends media`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(
            FakeMediaSessionSource(listOf(playing("com.spotify.music"), paused("com.spotify.music"))),
            node,
        ).run()

        assertEquals(
            listOf<TriggerCall>(TriggerCall.Started(EventKind.MEDIA, UNRANKED_PRIORITY), TriggerCall.Ended(EventKind.MEDIA)),
            node.calls,
        )
    }

    /** Apps update their session constantly - position, metadata, buffering. */
    @Test
    fun `repeated playing updates for one session do not double-emit`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(
            FakeMediaSessionSource(List(4) { playing("com.spotify.music") }),
            node,
        ).run()

        assertEquals(listOf<TriggerCall>(TriggerCall.Started(EventKind.MEDIA, UNRANKED_PRIORITY)), node.calls)
    }

    /**
     * The reference device really does have Spotify and Audible active at
     * once. The headset must not be released because one of two audio
     * sources stopped.
     */
    @Test
    fun `a second concurrent session does not emit a second start`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(
            FakeMediaSessionSource(listOf(playing("com.spotify.music"), playing("com.audible.application"))),
            node,
        ).run()

        assertEquals(listOf<TriggerCall>(TriggerCall.Started(EventKind.MEDIA, UNRANKED_PRIORITY)), node.calls)
    }

    @Test
    fun `stopping one of two concurrent sessions does not end media`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(
            FakeMediaSessionSource(
                listOf(playing("com.spotify.music"), playing("com.audible.application"), paused("com.spotify.music")),
            ),
            node,
        ).run()

        assertEquals(listOf<TriggerCall>(TriggerCall.Started(EventKind.MEDIA, UNRANKED_PRIORITY)), node.calls)
    }

    @Test
    fun `media ends only once the last playing session stops`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(
            FakeMediaSessionSource(
                listOf(
                    playing("com.spotify.music"),
                    playing("com.audible.application"),
                    paused("com.spotify.music"),
                    paused("com.audible.application"),
                ),
            ),
            node,
        ).run()

        assertEquals(
            listOf<TriggerCall>(TriggerCall.Started(EventKind.MEDIA, UNRANKED_PRIORITY), TriggerCall.Ended(EventKind.MEDIA)),
            node.calls,
        )
    }

    /**
     * A vanished session can never send another update, so it must be
     * forgotten - otherwise media would never end.
     */
    @Test
    fun `a session disappearing while playing ends media`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(
            FakeMediaSessionSource(listOf(playing("com.spotify.music"), MediaSessionEvent.Gone("com.spotify.music"))),
            node,
        ).run()

        assertEquals(
            listOf<TriggerCall>(TriggerCall.Started(EventKind.MEDIA, UNRANKED_PRIORITY), TriggerCall.Ended(EventKind.MEDIA)),
            node.calls,
        )
    }

    /**
     * Audible sits in STATE_NONE indefinitely on the reference device -
     * a session existing is not a session playing.
     */
    @Test
    fun `a session that never plays emits nothing`() = runTest {
        val node = RecordingEventLifecycle()
        MediaTriggerMonitor(
            FakeMediaSessionSource(listOf(paused("com.audible.application"), MediaSessionEvent.Gone("com.audible.application"))),
            node,
        ).run()

        assertEquals(emptyList<TriggerCall>(), node.calls)
    }
}
