package com.thrw.adapter.android.status

import com.thrw.adapter.android.protocol.CommandFailureReason
import com.thrw.adapter.android.protocol.CommandOutcome
import com.thrw.adapter.android.protocol.CommandType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * A claim or release this node was told to perform and could not (#309).
 *
 * Structured rather than a formatted string: the node records what
 * happened, the UI decides how to say it. Kotlin mirror of
 * `adapter-mac`'s `CommandFailure` — change both together.
 */
data class CommandFailure(
    val type: CommandType,
    /** [CommandOutcome.FAILED] or [CommandOutcome.TIMED_OUT] — never SUCCEEDED. */
    val outcome: CommandOutcome,
    /**
     * Absent for a timeout: ADR 0019 separates "the headset said no"
     * from "nothing answered at all", and only the first has a reason.
     */
    val reason: CommandFailureReason?,
)

/**
 * The most recent command failure, or null since the last success.
 *
 * ## Why this exists
 *
 * Before #309 a failed command reached `Log.e` and stopped there. The
 * relay learned about it — ADR 0019's outcome is published either way —
 * but the person holding the phone did not, and the notification went on
 * reading exactly as it had. `scenarios.md`'s R3 ("headset in its case
 * or out of range when a claim is made") requires that the user is told;
 * this is what the notification reads to tell them.
 *
 * ## A StateFlow, unlike the Mac's equivalent
 *
 * `adapter-mac` can store this behind a lock and read it when a menu
 * opens — nobody reads a closed menu. The Android notification is
 * permanently on screen, so a value nothing pushes would sit there stale
 * until the next unrelated refresh. Same reasoning as [HolderState]'s,
 * and it costs nothing while nothing is failing.
 *
 * ## Cleared by success, not by a timer
 *
 * A failure notice that expires on a clock would claim things are fine
 * while they are still broken. Clearing on the next *successful* command
 * means the readout is only ever "the last thing thrw tried to do
 * failed" or nothing — the rule the status line has followed since #213
 * replaced its static blurb.
 */
class LastCommandFailure {
    private val _failure = MutableStateFlow<CommandFailure?>(null)

    /** Emits on every change, replaying the current value to new collectors. */
    val failure: StateFlow<CommandFailure?> = _failure.asStateFlow()

    fun record(failure: CommandFailure) {
        _failure.value = failure
    }

    /**
     * A command succeeded, so whatever failed before is no longer the
     * most recent thing that happened.
     */
    fun clear() {
        _failure.value = null
    }

    fun current(): CommandFailure? = _failure.value
}

/**
 * Which single line the notification shows (#309).
 *
 * A pure function, in `status/` beside [nodeStatus] and `claimAction`,
 * for the same reason those are: the precedence *is* the decision here,
 * and it is easy to get subtly wrong. Buried in the service it could
 * only be tested by standing up a foreground service.
 *
 * Order is deliberate. A failed **tap** comes first: the user just acted
 * and deserves to know it did not take. A failed **command** comes next
 * — thrw attempted something and could not finish it, which may be about
 * a switch the user never asked for. The ordinary status line comes
 * last, because it is still true in both of those cases, and saying only
 * it is exactly how both stayed invisible.
 *
 * Returns a string resource id rather than a string so the caller keeps
 * ownership of the resources and this stays unit-testable without a
 * `Context`.
 */
fun notificationTextRes(
    claimFailed: Boolean,
    failure: CommandFailure?,
    statusRes: Int?,
    defaultRes: Int,
    res: NotificationTextResources,
): Int {
    if (claimFailed) return res.claimFailed
    if (failure != null) {
        if (failure.type == CommandType.RELEASE) return res.commandFailedRelease
        return when {
            failure.outcome == CommandOutcome.TIMED_OUT -> res.commandFailedNoResponse
            failure.reason == CommandFailureReason.TARGET_DEVICE_UNREACHABLE ->
                res.commandFailedUnreachable
            failure.reason == CommandFailureReason.BLUETOOTH_UNAVAILABLE ->
                res.commandFailedBluetooth
            // SUPERSEDED_BY_NEWER_COMMAND and anything added later: a
            // superseded command is idempotency working correctly, not a
            // switch that went wrong, so it deliberately falls through to
            // the ordinary status line rather than alarming the user.
            else -> statusRes ?: defaultRes
        }
    }
    return statusRes ?: defaultRes
}

/**
 * The resource ids [notificationTextRes] may return.
 *
 * Passed in rather than referenced directly so the decision can be
 * tested without Android's generated `R` class.
 */
data class NotificationTextResources(
    val claimFailed: Int,
    val commandFailedUnreachable: Int,
    val commandFailedNoResponse: Int,
    val commandFailedBluetooth: Int,
    val commandFailedRelease: Int,
)
