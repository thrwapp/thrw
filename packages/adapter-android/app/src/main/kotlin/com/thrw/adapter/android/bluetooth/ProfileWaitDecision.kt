package com.thrw.adapter.android.bluetooth

import android.bluetooth.BluetoothProfile

/**
 * What [AndroidBluetoothClassicGateway]'s profile-state poll should do
 * on this iteration (#264).
 */
enum class ProfileWaitDecision {
    /** A driven profile is at the target state. Done. */
    REACHED,

    /** The headset accepted the request and then went back to DISCONNECTED. */
    REFUSED,

    /**
     * The headset never even started connecting. Off, in its case, or
     * out of range.
     */
    UNREACHABLE,

    /** Nothing conclusive yet. */
    KEEP_WAITING,
}

/**
 * How long a connect may sit with every driven profile still at
 * `STATE_DISCONNECTED` before it is called unreachable (#264).
 *
 * ## Where this number comes from
 *
 * It is a **reasoned margin, not a measurement**, and the distinction
 * matters enough to write down - #264's criterion 3 is explicit that a
 * threshold picked to make a test pass would be worse than the coarse
 * label it replaces, because turning a working switch into a reported
 * failure is the more damaging error.
 *
 * The reasoning:
 *
 * - A successful claim measures **~4.9s end to end** on the reference
 *   Pixel, of which **<1s** is relay-to-command delivery (#254,
 *   docs/handoffs/254.md). So the on-device connect is roughly 4s.
 * - Nearly all of that 4s is spent *after* the profile reaches
 *   `STATE_CONNECTING`, in the baseband and profile handshake with the
 *   headset. The CONNECTING transition itself is a **local** state
 *   change, made when the stack accepts our request - it does not wait
 *   on the remote device, so it should land in milliseconds.
 * - 3s is therefore around 3x the whole window in which a reachable
 *   device could plausibly still be at DISCONNECTED, and 30x the
 *   [PROFILE_STATE_POLL_MS] poll interval, so it cannot be a sampling
 *   artefact.
 *
 * It still saves 5 of the 8 seconds the outer bound would otherwise
 * spend (#244), which is criterion 2.
 *
 * ## What would falsify it
 *
 * A device where the stack legitimately leaves a profile at
 * DISCONNECTED for over 3s before starting - a connect queued behind
 * the headset's own teardown from the *other* device would be the
 * candidate, since that is precisely the handover case. That should
 * surface as CONNECTING rather than DISCONNECTED (the stack has
 * accepted the request and is retrying), which is why this only fires
 * when CONNECTING was **never** observed. If it turns out to be wrong,
 * the symptom is `target_device_unreachable` appearing on switches that
 * used to succeed - watch that rate rather than trusting this comment.
 */
const val UNREACHABLE_AFTER_MS: Long = 3_000L

/**
 * Decides whether a profile-state poll can stop, and why.
 *
 * Pure, and separated from the gateway for the usual reason in this
 * package: [AndroidBluetoothClassicGateway] needs real
 * `android.bluetooth` proxies and a real adapter, so it has no unit
 * tests at all. This is where the only interesting judgement lives, so
 * this is the part that gets tested - same split [nodeStatus] and
 * `CommandSequenceGate` use.
 *
 * @param states the current connection state of each *driven* profile.
 * @param sawConnecting whether `STATE_CONNECTING` has been observed at
 *   any point during this wait. The caller tracks it across iterations.
 * @param elapsedMs how long this wait has been running.
 */
fun profileWaitDecision(
    states: List<Int>,
    targetState: Int,
    sawConnecting: Boolean,
    elapsedMs: Long,
    unreachableAfterMs: Long = UNREACHABLE_AFTER_MS,
): ProfileWaitDecision {
    if (states.any { it == targetState }) return ProfileWaitDecision.REACHED

    // Only a connect can be refused or find nothing there. A disconnect
    // that is not yet at DISCONNECTED is simply still in progress, and
    // the outer bound owns how long that may take.
    if (targetState != BluetoothProfile.STATE_CONNECTED) return ProfileWaitDecision.KEEP_WAITING

    val allDisconnected = states.all { it == BluetoothProfile.STATE_DISCONNECTED }
    if (!allDisconnected) return ProfileWaitDecision.KEEP_WAITING

    // Accepted, then dropped back: a refusal, and known immediately
    // (#257). Checked before the unreachable case because it is the
    // stronger signal - it needs no timer at all.
    if (sawConnecting) return ProfileWaitDecision.REFUSED

    // Never left DISCONNECTED. Before #264 this ran to the 8s bound and
    // surfaced as `timed_out`, which is honest but puts a headset in its
    // case - the most common real-world failure there is - in the same
    // bucket as a genuinely stuck adapter (ADR 0019).
    //
    // Still needs the timer: DISCONNECTED is legitimately the state for
    // a moment right after the request is accepted, which is the same
    // reason the refusal case above waits for CONNECTING first.
    if (elapsedMs >= unreachableAfterMs) return ProfileWaitDecision.UNREACHABLE

    return ProfileWaitDecision.KEEP_WAITING
}
