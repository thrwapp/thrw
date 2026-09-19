package com.thrw.adapter.android.triggers

import kotlinx.coroutines.flow.Flow

/**
 * One media session's playback state, reduced to what the trigger
 * actually needs. Pure Kotlin mirror of the two `MediaController` facts
 * [MediaTriggerMonitor] reads, kept free of `android.media.session` so
 * the monitor is unit-testable - same split [NotificationSource] and
 * [CallStateSource] already use.
 *
 * [key] identifies the session across updates. `MediaSession.Token` is
 * the natural identity but isn't a stable string, so the real source
 * derives one (package name is sufficient in practice: a package does not
 * run two independent media sessions simultaneously in any case this
 * adapter cares about).
 */
data class MediaSessionState(
    val key: String,
    val isPlaying: Boolean,
)

/** A media session appearing, changing state, or going away. */
sealed interface MediaSessionEvent {
    /** A session reported its current playback state. */
    data class Changed(val session: MediaSessionState) : MediaSessionEvent

    /**
     * A session disappeared entirely - the app was killed, or dropped its
     * session, without ever reporting a stopped state. Distinct from
     * [Changed] with `isPlaying = false`, because a vanished session can
     * never send another update and must be forgotten rather than tracked
     * as idle.
     */
    data class Gone(val key: String) : MediaSessionEvent
}

/**
 * Where playback state comes from. Faked in tests; the real
 * implementation sits behind `MediaSessionManager.getActiveSessions`,
 * which needs the notification-listener access this app already holds
 * (#107/#109) - so this trigger needs no new permission.
 *
 * Duplicate [MediaSessionEvent.Changed] events for the same key are
 * expected and fine: apps update their session constantly (position,
 * buffering, metadata), and [MediaTriggerMonitor] de-duplicates.
 */
interface MediaSessionSource {
    fun sessions(): Flow<MediaSessionEvent>
}
