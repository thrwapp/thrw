package com.thrw.adapter.android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Starts [AdapterForegroundService] on device boot.
 *
 * Judgment call (#96's acceptance criterion 2 leaves the exact trigger to
 * the implementer): boot rather than app launch, because there is no
 * launcher `Activity` anywhere in this codebase yet - #96 is a composition
 * root only, no UI work has landed for "app launch" to mean anything.
 * Once a launcher Activity exists, it's a natural second place to also
 * (re)start the service; this receiver doesn't need to change for that to
 * be added. See docs/handoffs/96.md.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        context.startForegroundService(Intent(context, AdapterForegroundService::class.java))
    }
}
