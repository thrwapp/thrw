package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind

/**
 * Turns notifications (via [NotificationSource]) into the node's `voip`
 * trigger - architecture.md's rule 3, "VoIP session started on any node -
 * Zoom/Meet/Teams/WhatsApp".
 *
 * ## The heuristic
 *
 * A posted notification counts as an active VoIP call when **all** of
 * these hold ([isActiveVoipCall]):
 *
 * 1. **It is call-shaped**: `category == "call"` (`CATEGORY_CALL`) or its
 *    style is `Notification.CallStyle`. This is what makes the trigger
 *    app-agnostic rather than an allowlist of package names - the relay
 *    "never assumes a platform's capabilities" (architecture.md) and, in
 *    the same spirit, the adapter shouldn't need a code change to learn
 *    about a new conferencing app. Every app in architecture.md's list
 *    posts one of the two.
 * 2. **It is ongoing**: `FLAG_ONGOING_EVENT` or `FLAG_FOREGROUND_SERVICE`
 *    is set. An app in a call holds a foreground service for the audio
 *    session; a *missed*-call or voicemail notification (also
 *    `category == "call"`) does not, which is what this condition throws
 *    out.
 * 3. **It is not a group summary** (`FLAG_GROUP_SUMMARY`): summaries
 *    duplicate their children, and would double-count.
 * 4. **It is not ringing or being screened**: for `CallStyle`
 *    notifications, `EXTRA_CALL_TYPE` distinguishes `CALL_TYPE_ONGOING`
 *    from `CALL_TYPE_INCOMING` / `CALL_TYPE_SCREENING`, and only the first
 *    is an active call. This is the same line [CallTriggerMonitor] draws
 *    for `RINGING`, and for the same ADR 0011 reason.
 * 5. **It is not from a dialer/telecom package** ([telephonyPackages]): the
 *    system dialer posts an ongoing `CATEGORY_CALL` notification for an
 *    ordinary cellular call, which `TelephonyManager` already reports as
 *    `call`. Without this, one phone call is reported twice, as rule 1 and
 *    rule 3.
 *
 * ## Sessions
 *
 * Qualifying notifications are counted by key, and only the transitions
 * that matter are reported: `emitEvent("voip", ...)` when the first
 * session appears, `endEvent("voip")` when the last one goes away. So a
 * call notification updating itself once a second doesn't spam the relay,
 * and a Zoom call overlapping a WhatsApp call produces one trigger, not
 * two starts and a premature end.
 *
 * A notification that stops qualifying while keeping its key (the usual
 * "call ended" in-place update) is treated exactly like a removal, since
 * apps don't reliably remove the notification promptly.
 *
 * ## Known limitations
 *
 * - An app that posts an ongoing `CATEGORY_CALL` notification *without*
 *   `CallStyle` while merely ringing is a false positive: there's no
 *   `EXTRA_CALL_TYPE` to check, so condition 4 can't fire.
 * - The reverse: an app that never marks its in-call notification ongoing
 *   or foreground-service is a false negative and won't trigger at all.
 * - A VoIP app whose in-call notification is neither `CATEGORY_CALL` nor
 *   `CallStyle` (some in-house/enterprise clients) is invisible here.
 * - [telephonyPackages] defaults cover AOSP/Pixel dialers. An OEM dialer
 *   under a different package would double-report; the constructor takes
 *   the set so that's configuration, not a code change.
 * - Notification access is user-granted and revocable. If it's off, this
 *   monitor simply never sees anything - it can't tell that apart from "no
 *   calls are happening".
 *
 * No state machine here, and no priority decision: this reports what it
 * sees, the relay decides (architecture.md).
 */
class VoipTriggerMonitor(
    private val source: NotificationSource,
    private val node: EventLifecycle,
    private val telephonyPackages: Set<String> = DEFAULT_TELEPHONY_PACKAGES,
) {
    private val activeSessions = mutableSetOf<String>()

    /**
     * Collects notification events and reports trigger start/end. Suspends
     * until the source's flow completes or the calling coroutine is
     * cancelled.
     */
    suspend fun run() {
        source.notifications().collect { event -> onNotificationEvent(event) }
    }

    /**
     * Handles one notification event. Exposed separately from [run] so a
     * caller already inside `NotificationListenerService`'s callbacks (or a
     * test) can drive it directly.
     */
    suspend fun onNotificationEvent(event: NotificationEvent) {
        when (event) {
            is NotificationEvent.Posted ->
                if (isActiveVoipCall(event.notification)) {
                    startSession(event.notification.key)
                } else {
                    endSession(event.notification.key)
                }

            is NotificationEvent.Removed -> endSession(event.key)
        }
    }

    /** The heuristic itself - see this class's kdoc for each condition. */
    fun isActiveVoipCall(notification: PostedNotification): Boolean {
        if (notification.packageName in telephonyPackages) return false

        val callShaped =
            notification.category == CATEGORY_CALL || notification.template == CALL_STYLE_TEMPLATE
        if (!callShaped) return false

        val ongoing = notification.flags and
            (NotificationFlags.ONGOING_EVENT or NotificationFlags.FOREGROUND_SERVICE) != 0
        if (!ongoing) return false

        if (notification.flags and NotificationFlags.GROUP_SUMMARY != 0) return false

        return notification.callType == null || notification.callType == CallType.ONGOING
    }

    private suspend fun startSession(key: String) {
        val wasEmpty = activeSessions.isEmpty()
        if (!activeSessions.add(key)) return
        if (wasEmpty) node.emitEvent(EventKind.VOIP, UNRANKED_PRIORITY)
    }

    private suspend fun endSession(key: String) {
        if (!activeSessions.remove(key)) return
        if (activeSessions.isEmpty()) node.endEvent(EventKind.VOIP)
    }

    companion object {
        /**
         * Packages whose ongoing call notification is a *cellular* call
         * that `TelephonyManager` already reports - AOSP and Pixel dialers
         * plus the telecom/phone system services.
         */
        val DEFAULT_TELEPHONY_PACKAGES: Set<String> = setOf(
            "com.android.dialer",
            "com.google.android.dialer",
            "com.android.phone",
            "com.android.server.telecom",
        )
    }
}
