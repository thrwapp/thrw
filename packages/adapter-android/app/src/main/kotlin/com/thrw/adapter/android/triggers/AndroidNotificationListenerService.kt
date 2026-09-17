package com.thrw.adapter.android.triggers

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * The real [NotificationSource]'s system-facing half: bridges
 * `NotificationListenerService`'s instance callbacks
 * (`onNotificationPosted`/`onNotificationRemoved`/`onListenerConnected`) to
 * a [Flow] other components can collect - the implementation
 * [NotificationSource]'s kdoc anticipated landing once the module moved to
 * AGP (#68 -> #96; see docs/handoffs/96.md).
 *
 * Android instantiates `NotificationListenerService` subclasses itself
 * (there's no app-controlled constructor call), and this instance's
 * lifecycle is independent of
 * [com.thrw.adapter.android.AdapterForegroundService]'s - the user grants
 * or revokes notification access at any time in Settings, and the system
 * can create/destroy this instance on its own schedule. So events are
 * published on a companion-object [MutableSharedFlow] - a well-established
 * Android pattern for exactly this seam - rather than anything
 * instance-scoped, and [AndroidNotificationSource] (the actual
 * [NotificationSource] `AdapterForegroundService` wires up) just collects
 * the companion's flow.
 *
 * Declared in `AndroidManifest.xml` with the
 * `BIND_NOTIFICATION_LISTENER_SERVICE` permission; the user must grant
 * notification access in Settings for it to ever connect - there is no
 * runtime-permission dialog for this, and no in-app flow prompting for it
 * yet (out of scope here, see docs/handoffs/96.md).
 */
class AndroidNotificationListenerService : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        // NotificationSource's kdoc: "the getActiveNotifications() replay a
        // listener does on connect" - anything already posted before this
        // listener connected (or reconnected after being toggled off) has
        // to be replayed, or VoipTriggerMonitor would miss a call that was
        // already ongoing when this service (re)connected.
        activeNotifications?.forEach { events.tryEmit(NotificationEvent.Posted(it.toPostedNotification())) }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        events.tryEmit(NotificationEvent.Posted(sbn.toPostedNotification()))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        events.tryEmit(NotificationEvent.Removed(sbn.key))
    }

    private fun StatusBarNotification.toPostedNotification(): PostedNotification {
        val extras = notification.extras
        return PostedNotification(
            key = key,
            packageName = packageName,
            category = notification.category,
            flags = notification.flags,
            template = extras.getString(Notification.EXTRA_TEMPLATE),
            callType = if (extras.containsKey(Notification.EXTRA_CALL_TYPE)) {
                extras.getInt(Notification.EXTRA_CALL_TYPE)
            } else {
                null
            },
        )
    }

    companion object {
        // replay = 0: onListenerConnected's replay above already covers
        // "already posted before this collector started", so a fresh
        // collector doesn't also need flow-level replay. A generous
        // extraBufferCapacity means a burst of notification updates can't
        // suspend or drop against a momentarily slow collector - tryEmit
        // (used above) is non-suspending, so it needs somewhere to land.
        private val events = MutableSharedFlow<NotificationEvent>(replay = 0, extraBufferCapacity = 64)

        /** The flow [AndroidNotificationSource] collects. */
        val notifications: SharedFlow<NotificationEvent> get() = events.asSharedFlow()
    }
}

/**
 * [NotificationSource] that collects
 * [AndroidNotificationListenerService.notifications]. A separate, tiny
 * class - rather than making the listener service itself the
 * [NotificationSource] - because [VoipTriggerMonitor] is constructed in
 * [com.thrw.adapter.android.AdapterForegroundService], a different
 * component instance the system may create independently of, and with a
 * different lifecycle than, the listener service.
 */
class AndroidNotificationSource : NotificationSource {
    override fun notifications(): Flow<NotificationEvent> = AndroidNotificationListenerService.notifications
}
