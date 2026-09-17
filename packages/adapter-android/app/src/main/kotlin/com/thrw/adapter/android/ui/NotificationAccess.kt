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
}
