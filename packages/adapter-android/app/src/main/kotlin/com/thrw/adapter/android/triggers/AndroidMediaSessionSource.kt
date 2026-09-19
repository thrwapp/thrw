package com.thrw.adapter.android.triggers

import android.content.ComponentName
import android.content.Context
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Real [MediaSessionSource], backed by `MediaSessionManager`.
 *
 * Reading other apps' media sessions requires notification-listener
 * access, which this app already holds for VoIP detection (#107/#109) -
 * so this trigger adds **no new permission and no new user-facing grant**.
 * The same [AndroidNotificationListenerService] component is what
 * `getActiveSessions` is authorised against.
 *
 * Not unit-tested, for the same reason [AndroidCallStateSource] and
 * [AndroidNotificationListenerService] aren't: this module's tests run
 * against a stubbed `android.jar` where every framework call returns a
 * default. [MediaTriggerMonitor] holds the logic and is tested against a
 * fake of the interface above.
 *
 * Session identity is the package name. `MediaSession.Token` is the
 * natural identity but isn't a stable string across controller
 * instances; a package running two independent simultaneous sessions is
 * not a case this adapter needs to distinguish.
 */
class AndroidMediaSessionSource(
    private val context: Context,
    private val listenerComponent: ComponentName,
) : MediaSessionSource {

    override fun sessions(): Flow<MediaSessionEvent> = callbackFlow {
        val manager = context.getSystemService(MediaSessionManager::class.java)
        if (manager == null) {
            close()
            return@callbackFlow
        }

        // One callback per controller, tracked so they can be
        // unregistered when the controller set changes or the flow ends -
        // a leaked callback keeps a dead controller alive and reports
        // state for a session nothing is watching any more.
        val callbacks = mutableMapOf<String, Pair<MediaController, MediaController.Callback>>()

        fun playing(state: PlaybackState?) = state?.state == PlaybackState.STATE_PLAYING

        fun rebind(controllers: List<MediaController>) {
            val live = controllers.associateBy { it.packageName }

            // Sessions that went away entirely: report Gone so the monitor
            // forgets them rather than tracking them as idle forever.
            for ((key, registered) in callbacks - live.keys) {
                registered.first.unregisterCallback(registered.second)
                callbacks.remove(key)
                trySend(MediaSessionEvent.Gone(key))
            }

            for ((key, controller) in live) {
                if (callbacks.containsKey(key)) continue
                val cb = object : MediaController.Callback() {
                    override fun onPlaybackStateChanged(state: PlaybackState?) {
                        trySend(MediaSessionEvent.Changed(MediaSessionState(key, playing(state))))
                    }

                    override fun onSessionDestroyed() {
                        trySend(MediaSessionEvent.Gone(key))
                    }
                }
                controller.registerCallback(cb)
                callbacks[key] = controller to cb
                // Emit the current state immediately: registerCallback does
                // not replay, so a session already playing when this starts
                // would otherwise be invisible until its next change.
                trySend(MediaSessionEvent.Changed(MediaSessionState(key, playing(controller.playbackState))))
            }
        }

        val onActiveSessionsChanged =
            MediaSessionManager.OnActiveSessionsChangedListener { controllers -> rebind(controllers.orEmpty()) }

        manager.addOnActiveSessionsChangedListener(onActiveSessionsChanged, listenerComponent)
        rebind(manager.getActiveSessions(listenerComponent))

        awaitClose {
            manager.removeOnActiveSessionsChangedListener(onActiveSessionsChanged)
            callbacks.values.forEach { (controller, cb) -> controller.unregisterCallback(cb) }
            callbacks.clear()
        }
    }
}
