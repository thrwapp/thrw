package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind

/**
 * Turns media playback into the node's `media` trigger - architecture.md's
 * rule 4, and the trigger behind the product's most ordinary case: music
 * starts on the phone, so the headset should come away from the Mac.
 *
 * ## What counts as "playing"
 *
 * Exactly one thing: a session reporting `PlaybackState.STATE_PLAYING`,
 * reduced to [MediaSessionState.Playback] at the source boundary.
 *
 * Deliberately **not** counted, each for a reason:
 * - **`STATE_PAUSED` / `STATE_STOPPED` / `STATE_NONE`**: not playing.
 *   `STATE_NONE` in particular is what an app reports when it holds a
 *   session but has never played anything - the reference device has
 *   Audible sitting in exactly that state indefinitely.
 *
 * ## `STATE_BUFFERING` is neither a start nor a stop (#288)
 *
 * It does not start the trigger, and it does not end one that is already
 * running. A buffering session is left exactly as it was.
 *
 * An earlier version of this comment argued that buffering should simply
 * not count, because "a track that is loading is on its way to playing,
 * but treating it as playing means a skipped track or a momentary
 * network stall can start and stop the trigger repeatedly". That
 * reasoning is correct for buffering **before playback starts** -
 * `NONE -> BUFFERING -> PLAYING` - and it is why buffering still does
 * not start the trigger.
 *
 * It is exactly wrong for buffering **during** playback, which is what
 * actually happens. Measured on the reference Pixel with Spotify playing
 * continuously and sounding perfect:
 *
 * ```
 * 14:58:42.159  PLAYING   -> BUFFERING
 * 14:58:44.420  BUFFERING -> PLAYING     (2.26s)
 * 15:02:42.316  PLAYING   -> BUFFERING
 * 15:02:43.386  BUFFERING -> PLAYING     (1.07s)
 * ```
 *
 * Treating that as "stopped" published an `event_end` and then a fresh
 * `media` a second later, every few minutes, for as long as music played
 * - the flapping the old comment set out to prevent, caused by the rule
 * meant to prevent it. With a contending node it is #236-shaped
 * oscillation.
 *
 * The distinction is what preceded the buffering, which is why this is a
 * third state rather than a boolean: the same `STATE_BUFFERING` means
 * "not yet" before playback and "still playing" during it.
 *
 * ## Multiple simultaneous sessions
 *
 * The reference device genuinely has several active sessions at once
 * (Spotify and Audible both `active=true`). "Media is playing" means
 * **any** tracked session is playing, and the trigger only ends when the
 * last one stops - the same union-of-active-sessions rule
 * [VoipTriggerMonitor] applies to concurrent VoIP apps, for the same
 * reason: the headset should not be released because one of two audio
 * sources stopped.
 *
 * ## What this does not know
 *
 * It reports; it does not decide. Priority lives server-side in the relay
 * (architecture.md), so this never compares media against a call - it
 * simply says whether media is playing here.
 */
class MediaTriggerMonitor(
    private val source: MediaSessionSource,
    private val node: EventLifecycle,
) {
    /** Keys of sessions currently playing. Empty means no media trigger. */
    private val playingSessions = mutableSetOf<String>()

    /**
     * Collects session events and reports trigger start/end. Suspends
     * until the source's flow completes or the calling coroutine is
     * cancelled.
     */
    suspend fun run() {
        source.sessions().collect { event -> onSessionEvent(event) }
    }

    /**
     * Handles one session event. Exposed separately from [run] so a
     * caller already inside `MediaSessionManager`'s callbacks (or a test)
     * can drive it directly.
     */
    suspend fun onSessionEvent(event: MediaSessionEvent) {
        when (event) {
            is MediaSessionEvent.Changed -> when (event.session.playback) {
                MediaSessionState.Playback.PLAYING -> startSession(event.session.key)
                MediaSessionState.Playback.STOPPED -> endSession(event.session.key)
                // #288. Neither a start nor a stop: a session already
                // tracked stays tracked, one that is not stays untracked.
                // See "What counts as playing" above for why.
                MediaSessionState.Playback.TRANSIENT -> Unit
            }

            is MediaSessionEvent.Gone -> endSession(event.key)
        }
    }

    private suspend fun startSession(key: String) {
        val wasEmpty = playingSessions.isEmpty()
        if (!playingSessions.add(key)) return
        if (wasEmpty) node.emitEvent(EventKind.MEDIA, UNRANKED_PRIORITY)
    }

    private suspend fun endSession(key: String) {
        if (!playingSessions.remove(key)) return
        if (playingSessions.isEmpty()) node.endEvent(EventKind.MEDIA)
    }
}
