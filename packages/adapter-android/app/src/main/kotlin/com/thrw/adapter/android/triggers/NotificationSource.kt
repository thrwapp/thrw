package com.thrw.adapter.android.triggers

import kotlinx.coroutines.flow.Flow

/**
 * The fields of a posted notification the VoIP heuristic reads, and
 * nothing else. Every one maps to something
 * `NotificationListenerService.onNotificationPosted(StatusBarNotification)`
 * hands over:
 *
 * - [key] - `StatusBarNotification.getKey()`, the stable per-notification
 *   identity that `onNotificationRemoved` reports back.
 * - [packageName] - `StatusBarNotification.getPackageName()`.
 * - [category] - `Notification.category` (`CATEGORY_CALL` = `"call"`).
 * - [flags] - `Notification.flags`, read via the `FLAG_*` constants in
 *   [NotificationFlags].
 * - [template] - `Notification.extras.getString(EXTRA_TEMPLATE)`, which is
 *   the style class name, e.g. [CALL_STYLE_TEMPLATE].
 * - [callType] - `Notification.extras.getInt(EXTRA_CALL_TYPE)` for
 *   `CallStyle` notifications; null when the notification isn't
 *   `CallStyle` or predates it (API 31).
 */
data class PostedNotification(
    val key: String,
    val packageName: String,
    val category: String? = null,
    val flags: Int = 0,
    val template: String? = null,
    val callType: Int? = null,
)

/** `Notification.category` values this adapter cares about. */
const val CATEGORY_CALL: String = "call"

/** `Notification.extras`' `EXTRA_TEMPLATE` value for `Notification.CallStyle`. */
const val CALL_STYLE_TEMPLATE: String = "android.app.Notification\$CallStyle"

/** `Notification.flags` bits, same values as the framework constants. */
object NotificationFlags {
    const val ONGOING_EVENT: Int = 0x00000002
    const val FOREGROUND_SERVICE: Int = 0x00000040
    const val GROUP_SUMMARY: Int = 0x00000200
}

/** `Notification.CallStyle`'s `CALL_TYPE_*` constants, same values. */
object CallType {
    const val INCOMING: Int = 1
    const val ONGOING: Int = 2
    const val SCREENING: Int = 3
}

/** A posted-or-removed notification, as the listener service reports them. */
sealed interface NotificationEvent {
    data class Posted(val notification: PostedNotification) : NotificationEvent

    /** [key] is the `StatusBarNotification.getKey()` of the gone notification. */
    data class Removed(val key: String) : NotificationEvent
}

/**
 * Thin seam over `NotificationListenerService` that
 * [VoipTriggerMonitor] depends on, modeled on its two callbacks
 * (`onNotificationPosted` / `onNotificationRemoved`) plus the
 * `getActiveNotifications()` replay a listener does on connect. Requires
 * the user to grant notification access
 * (`BIND_NOTIFICATION_LISTENER_SERVICE`) - there is no way around that
 * consent for this trigger.
 *
 * Same reason this is an interface as `BluetoothClassicGateway` and
 * [CallStateSource]: no Android SDK on this module's classpath yet, and
 * real notifications can't be posted in the Gradle test runner. Tests fake
 * this; the `NotificationListenerService` subclass sits behind it later,
 * mapping each `StatusBarNotification` to a [PostedNotification].
 *
 * Duplicate [NotificationEvent.Posted] events for the same key are
 * expected and fine - apps update an ongoing call notification constantly
 * (call timer, mute state), and [VoipTriggerMonitor] de-duplicates.
 */
interface NotificationSource {
    fun notifications(): Flow<NotificationEvent>
}
