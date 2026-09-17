package com.thrw.adapter.android.ui

/**
 * The "is notification-listener access granted" check backing the status
 * line on [ProvisioningActivity] (#107).
 *
 * Unlike [AdapterPermissions]'s three permissions, there is no
 * `checkSelfPermission` equivalent for this special access - the standard
 * way to check it is `NotificationManagerCompat.getEnabledListenerPackages(context)`,
 * which reads `Settings.Secure`'s `enabled_notification_listeners` and
 * returns the package names it lists. [isGranted] is that containment
 * check pulled out as pure Kotlin (no `android.*` types), the same
 * seam-for-testability [AdapterPermissions.missing] uses for its injected
 * `isGranted` lambda - the caller does the real
 * `NotificationManagerCompat` call and passes the resulting `Set<String>`
 * in.
 */
object NotificationAccess {
    fun isGranted(packageName: String, enabledListenerPackages: Set<String>): Boolean =
        packageName in enabledListenerPackages

    /**
     * The `pkg/cls` form `Settings.EXTRA_FRAGMENT_ARG_KEY` expects to
     * deep-link `Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS` straight
     * to this app's row, matching `ComponentName.flattenToString()`'s
     * format. Built by hand rather than by calling `ComponentName` itself
     * so this stays plain-Kotlin and testable - `android.content.ComponentName`
     * is a stub under this module's unit-test `android.jar` and
     * `flattenToString()` would return null there rather than the real
     * value.
     */
    fun flattenedComponentName(packageName: String, className: String): String = "$packageName/$className"
}
