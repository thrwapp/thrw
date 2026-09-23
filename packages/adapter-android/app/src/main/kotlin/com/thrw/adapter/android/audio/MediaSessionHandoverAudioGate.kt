package com.thrw.adapter.android.audio

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.util.Log

/**
 * Real [HandoverAudioGate] for Android: pauses and resumes media
 * sessions through their transport controls (ADR 0022).
 *
 * Uses the same notification-listener grant the VoIP and media triggers
 * already require, so this adds **no new permission** - which is most of
 * why ADR 0022 chose pausing here while macOS mutes.
 *
 * Not unit-tested: this module's tests run without `MediaSessionManager`
 * or any session to drive. `AndroidNode` holds the decision of *when* to
 * call it and is tested against a fake of the interface, the same split
 * `AndroidMediaSessionSource` documents.
 *
 * ## Only what we paused is resumed
 *
 * [silence] records the sessions it actually paused, and [restore]
 * touches only those. Resuming every session would start playback the
 * user had deliberately paused before the handover - a strictly worse
 * outcome than the audio leak this exists to prevent, because the user
 * did not ask for it and has no idea why it happened.
 */
class MediaSessionHandoverAudioGate(
    context: Context,
    private val listenerComponent: ComponentName,
) : HandoverAudioGate {
    private val appContext = context.applicationContext

    /**
     * Package names of sessions paused by the most recent [silence].
     *
     * Guarded by `this` because the command loop and its outcome
     * reporting can overlap: a release arriving while a claim's
     * [restore] is still in flight is ordinary, not exceptional.
     */
    private val paused = mutableSetOf<String>()

    @SuppressLint("MissingPermission")
    override suspend fun silence() {
        val controllers = activeControllers() ?: return
        val justPaused = mutableSetOf<String>()
        for (controller in controllers) {
            if (controller.playbackState?.state != PlaybackState.STATE_PLAYING) continue
            runCatching { controller.transportControls.pause() }
                .onSuccess { justPaused += controller.packageName }
                .onFailure { Log.w(TAG, "could not pause ${controller.packageName}", it) }
        }
        synchronized(this) {
            paused.clear()
            paused += justPaused
        }
        if (justPaused.isNotEmpty()) Log.i(TAG, "silenced for handover: $justPaused")
    }

    @SuppressLint("MissingPermission")
    override suspend fun restore() {
        val toResume = synchronized(this) {
            val snapshot = paused.toSet()
            paused.clear()
            snapshot
        }
        if (toResume.isEmpty()) return

        val controllers = activeControllers() ?: return
        for (controller in controllers) {
            if (controller.packageName !in toResume) continue
            runCatching { controller.transportControls.play() }
                .onFailure { Log.w(TAG, "could not resume ${controller.packageName}", it) }
        }
        Log.i(TAG, "restored after handover: $toResume")
    }

    /**
     * `null` rather than an empty list when the manager or the grant is
     * missing, so [restore] can tell "nothing to do" from "could not
     * look" - clearing the paused set on the latter would strand
     * whatever we silenced.
     */
    @SuppressLint("MissingPermission")
    private fun activeControllers(): List<MediaController>? {
        val manager = appContext.getSystemService(MediaSessionManager::class.java) ?: return null
        return runCatching { manager.getActiveSessions(listenerComponent) }
            .onFailure { Log.w(TAG, "cannot read active sessions - notification access revoked?", it) }
            .getOrNull()
    }

    private companion object {
        private const val TAG = "HandoverAudioGate"
    }
}
