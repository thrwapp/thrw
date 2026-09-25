package com.thrw.adapter.android.status

import androidx.annotation.StringRes
import com.thrw.adapter.android.R

/**
 * The string resource for each status (#213).
 *
 * Separate from [NodeStatus] so the enum itself stays free of Android
 * types and can be tested without a resource table - the same split
 * `MediaSessionSource` uses to keep `MediaTriggerMonitor` testable.
 */
@get:StringRes
val NodeStatus.textRes: Int
    get() = when (this) {
        NodeStatus.PAUSED -> R.string.status_paused
        NodeStatus.DISCONNECTED -> R.string.status_disconnected
        NodeStatus.HOLDING -> R.string.status_holding
        NodeStatus.NOT_HOLDING -> R.string.status_not_holding
        NodeStatus.UNKNOWN -> R.string.status_unknown
    }
