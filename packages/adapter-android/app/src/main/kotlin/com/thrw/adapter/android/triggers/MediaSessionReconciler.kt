package com.thrw.adapter.android.triggers

/**
 * One live media session, reduced to what reconciliation actually needs
 * (#179). Deliberately free of `android.media.session` types so the
 * decision below can be tested.
 *
 * [token] is the session's identity - `MediaController.sessionToken` at
 * the call site. Compared with `==` and nothing else, so the reconciler
 * never has to know what it is.
 */
data class SessionRef(
    val key: String,
    val token: Any?,
    val isPlaying: Boolean,
)

/**
 * What [reconcileSessions] decided, as data rather than side effects.
 *
 * [unregister] and [register] are keys; the caller maps them back to
 * controllers. [events] is what to emit, already in the order it should
 * go out.
 */
data class Reconciliation(
    val unregister: List<String> = emptyList(),
    val register: List<String> = emptyList(),
    val events: List<MediaSessionEvent> = emptyList(),
)

/**
 * Decides what changed between the sessions currently tracked and the
 * sessions that are live.
 *
 * ## Why this is a pure function
 *
 * Two production bugs (#174, #175) were found in
 * [AndroidMediaSessionSource] the first time it ran on real hardware, and
 * **neither was reachable by any test**: this module's tests run against
 * a stubbed `android.jar` where `MediaSessionManager` and
 * `MediaController` calls are no-ops returning defaults, so the file
 * holding the decisions was the one file tests could not touch.
 * `MediaTriggerMonitor` is well covered and could not have caught either,
 * because neither was in the monitor.
 *
 * So the decisions live here, over an interface with no framework types,
 * and the caller is reduced to executing them. What is left there -
 * registering a callback, posting to a handler - contains no decisions.
 *
 * ## The rules, and the bug each one encodes
 *
 * - A tracked session whose package is no longer live is **gone**:
 *   unregister it and report it.
 * - A live session whose package is tracked **with the same token** is
 *   unchanged: do nothing. Emitting here would re-report a session that
 *   never stopped.
 * - A live session whose package is tracked with a **different token**
 *   has been *replaced*: unregister the old controller, register the new
 *   one, report its current state. This is #175. Identity is the token,
 *   not the package, precisely because the package is stable across
 *   controller instances - which is why a package check could not detect
 *   a replacement, left the source bound to a dead controller, and made
 *   it deaf to that app forever after the first session ended.
 * - A live session not tracked at all is **new**: register and report.
 *   Reporting immediately matters because `registerCallback` does not
 *   replay, so a session already playing when this starts would
 *   otherwise be invisible until its next change.
 */
fun reconcileSessions(tracked: Map<String, Any?>, live: List<SessionRef>): Reconciliation {
    val liveKeys = live.map { it.key }.toSet()
    val unregister = mutableListOf<String>()
    val register = mutableListOf<String>()
    val events = mutableListOf<MediaSessionEvent>()

    for (key in tracked.keys) {
        if (key !in liveKeys) {
            unregister += key
            events += MediaSessionEvent.Gone(key)
        }
    }

    for (ref in live) {
        val isTracked = tracked.containsKey(ref.key)
        if (isTracked && tracked[ref.key] == ref.token) continue
        // Replaced rather than new: the old controller must be released
        // before the new one is registered, or its callback outlives it.
        if (isTracked) unregister += ref.key
        register += ref.key
        events += MediaSessionEvent.Changed(MediaSessionState(ref.key, ref.isPlaying))
    }

    return Reconciliation(unregister = unregister, register = register, events = events)
}
