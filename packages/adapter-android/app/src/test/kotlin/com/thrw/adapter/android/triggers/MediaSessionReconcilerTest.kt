package com.thrw.adapter.android.triggers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The tests #175 could not have had (#179).
 *
 * `AndroidMediaSessionSource` used to hold this logic inline against
 * `MediaController`, which this module's tests cannot exercise - the
 * stubbed `android.jar` turns every framework call into a no-op. Two
 * production bugs lived there undetected until the trigger ran on real
 * hardware. These are the cases that broke.
 */
class MediaSessionReconcilerTest {
    private val spotify = "com.spotify.music"
    private val audible = "com.audible.application"

    @Test
    fun `a new session is registered and reported`() {
        val plan = reconcileSessions(
            tracked = emptyMap(),
            live = listOf(SessionRef(spotify, token = 1, playback = MediaSessionState.Playback.PLAYING)),
        )

        assertEquals(listOf(spotify), plan.register)
        assertEquals(emptyList(), plan.unregister)
        assertEquals(listOf(MediaSessionEvent.Changed(MediaSessionState(spotify, MediaSessionState.Playback.PLAYING))), plan.events)
    }

    /**
     * **This is #175.** Spotify destroyed session `/11` and created `/12`
     * on relaunch. The package is unchanged, so a package-keyed check saw
     * nothing to do, skipped the new controller, and left the source
     * bound to a dead one - deaf to that app forever. It fired exactly
     * once per app, then silently stopped.
     */
    @Test
    fun `a replaced session unregisters the old controller and registers the new one`() {
        val plan = reconcileSessions(
            tracked = mapOf(spotify to 11),
            live = listOf(SessionRef(spotify, token = 12, playback = MediaSessionState.Playback.PLAYING)),
        )

        assertEquals(listOf(spotify), plan.unregister, "the dead controller must be released")
        assertEquals(listOf(spotify), plan.register, "the new controller must be registered")
        assertEquals(listOf(MediaSessionEvent.Changed(MediaSessionState(spotify, MediaSessionState.Playback.PLAYING))), plan.events)
    }

    /**
     * The other half of #175's fix: identity is the token, so an
     * unchanged session must produce no work at all. Without this, every
     * rebind would tear down and re-register a session that never
     * stopped, and re-report it as though it had just started.
     */
    @Test
    fun `an unchanged session produces no actions`() {
        val plan = reconcileSessions(
            tracked = mapOf(spotify to 11),
            live = listOf(SessionRef(spotify, token = 11, playback = MediaSessionState.Playback.PLAYING)),
        )

        assertEquals(Reconciliation(), plan)
    }

    @Test
    fun `a session that disappeared is unregistered and reported gone`() {
        val plan = reconcileSessions(
            tracked = mapOf(spotify to 11),
            live = emptyList(),
        )

        assertEquals(listOf(spotify), plan.unregister)
        assertEquals(emptyList(), plan.register)
        assertEquals(listOf(MediaSessionEvent.Gone(spotify)), plan.events)
    }

    /**
     * The reference device genuinely runs several at once - Spotify and
     * Audible both hold active sessions - so one app's session ending
     * must not disturb another's.
     */
    @Test
    fun `one session going away leaves the others alone`() {
        val plan = reconcileSessions(
            tracked = mapOf(spotify to 11, audible to 21),
            live = listOf(SessionRef(audible, token = 21, playback = MediaSessionState.Playback.STOPPED)),
        )

        assertEquals(listOf(spotify), plan.unregister)
        assertEquals(emptyList(), plan.register)
        assertEquals(listOf(MediaSessionEvent.Gone(spotify)), plan.events)
    }

    /**
     * Ordering is a correctness property, not cosmetic: a `Gone` must
     * reach the monitor before the `Changed` for whatever replaced it, or
     * the monitor's set of playing sessions ends up with the departed one
     * removed *after* the new one was added.
     */
    @Test
    fun `departures are reported before arrivals`() {
        val plan = reconcileSessions(
            tracked = mapOf(spotify to 11),
            live = listOf(SessionRef(audible, token = 21, playback = MediaSessionState.Playback.PLAYING)),
        )

        assertEquals(
            listOf(
                MediaSessionEvent.Gone(spotify),
                MediaSessionEvent.Changed(MediaSessionState(audible, MediaSessionState.Playback.PLAYING)),
            ),
            plan.events,
        )
    }

    /**
     * A session that holds a controller but has never played reports
     * `STATE_NONE`, which the source maps to `playback = MediaSessionState.Playback.STOPPED`. It must
     * still be tracked - it is how Audible sits on the reference device
     * indefinitely - so that it is noticed when it does start.
     */
    @Test
    fun `an idle session is still registered`() {
        val plan = reconcileSessions(
            tracked = emptyMap(),
            live = listOf(SessionRef(audible, token = 21, playback = MediaSessionState.Playback.STOPPED)),
        )

        assertEquals(listOf(audible), plan.register)
        assertEquals(listOf(MediaSessionEvent.Changed(MediaSessionState(audible, MediaSessionState.Playback.STOPPED))), plan.events)
    }

    @Test
    fun `nothing tracked and nothing live is a no-op`() {
        assertEquals(Reconciliation(), reconcileSessions(emptyMap(), emptyList()))
        assertTrue(reconcileSessions(emptyMap(), emptyList()).events.isEmpty())
    }
}
