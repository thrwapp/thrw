package com.thrw.adapter.android.triggers

import android.content.ComponentName
import android.content.Context
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
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

        // Every registration below must happen on a thread with a Looper:
        // both `addOnActiveSessionsChangedListener` and
        // `MediaController.registerCallback` build a `Handler` from the
        // *calling* thread when they aren't given one, and this flow is
        // collected on `Dispatchers.Default`, whose workers have no Looper.
        // On a real device that threw `Can't create handler inside thread
        // ... that has not called Looper.prepare()` and took the whole
        // media trigger out - see #174. The framework offers no Executor
        // overload here (checked against android-35), so an explicit
        // main-looper Handler is the fix.
        //
        // Doing all of it on one thread also makes `callbacks` below
        // single-threaded: it was previously reachable from both the
        // collecting coroutine and the listener callback at once.
        val handler = Handler(Looper.getMainLooper())

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
                // Identity is the *session token*, not the package (#175).
                // A package is stable across controller instances, which is
                // precisely why "this package is already in the map" cannot
                // tell us the session was replaced. An app that destroys and
                // recreates its session - relaunching, or Spotify moving
                // between local and Connect playback - keeps its package in
                // `live`, so the `callbacks - live.keys` pass above removes
                // nothing and a package check would skip the new controller
                // forever, leaving this bound to a dead one and deaf to that
                // app. `MediaSession.Token` has value equality, so it is the
                // right test here.
                val existing = callbacks[key]
                if (existing != null && existing.first.sessionToken == controller.sessionToken) continue
                if (existing != null) {
                    existing.first.unregisterCallback(existing.second)
                    callbacks.remove(key)
                }
                val cb = object : MediaController.Callback() {
                    override fun onPlaybackStateChanged(state: PlaybackState?) {
                        trySend(MediaSessionEvent.Changed(MediaSessionState(key, playing(state))))
                    }

                    override fun onSessionDestroyed() {
                        // Drop the entry as well as reporting it: leaving a
                        // destroyed controller in the map is what made this
                        // deaf to the app's next session (#175).
                        callbacks.remove(key)
                        trySend(MediaSessionEvent.Gone(key))
                    }
                }
                controller.registerCallback(cb, handler)
                callbacks[key] = controller to cb
                // Emit the current state immediately: registerCallback does
                // not replay, so a session already playing when this starts
                // would otherwise be invisible until its next change.
                trySend(MediaSessionEvent.Changed(MediaSessionState(key, playing(controller.playbackState))))
            }
        }

        val onActiveSessionsChanged =
            MediaSessionManager.OnActiveSessionsChangedListener { controllers -> rebind(controllers.orEmpty()) }

        handler.post {
            // Anything thrown here is on the main looper, outside the node
            // runtime's CoroutineExceptionHandler (#161) - uncaught, it
            // kills the process rather than degrading one trigger. So it
            // closes the flow instead: `getActiveSessions` throws
            // SecurityException if notification-listener access is revoked
            // while running, which is a survivable loss of this trigger.
            try {
                manager.addOnActiveSessionsChangedListener(onActiveSessionsChanged, listenerComponent, handler)
                rebind(manager.getActiveSessions(listenerComponent))
            } catch (e: Exception) {
                close(e)
            }
        }

        awaitClose {
            // Also on the handler, so unregistering can't race a callback
            // that is mid-flight on the main looper.
            handler.post {
                manager.removeOnActiveSessionsChangedListener(onActiveSessionsChanged)
                callbacks.values.forEach { (controller, cb) -> controller.unregisterCallback(cb) }
                callbacks.clear()
            }
        }
    }
}
