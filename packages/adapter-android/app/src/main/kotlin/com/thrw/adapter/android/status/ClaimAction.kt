package com.thrw.adapter.android.status

import com.thrw.adapter.android.protocol.EventKind

/**
 * What the notification's claim action should say, and whether tapping
 * it does anything (#234). Kotlin mirror of `adapter-mac`'s
 * `ClaimAction` - the two must not diverge (#234 criterion 6).
 *
 * A value type with a pure constructor, for the same reason
 * [nodeStatus] is one: the precedence between the inputs is the entire
 * decision, it is easy to get subtly wrong, and it is untestable once
 * buried in a `Notification.Builder`.
 */
data class ClaimAction(
    val title: String,
    /** false renders a readout rather than a tappable action. */
    val isEnabled: Boolean,
)

/**
 * Derives the claim action from what this node knows.
 *
 * ## The rule, and the bug it replaces
 *
 * Before #234 the title came from `ManualClaim.isHeld()` alone, which
 * records only whether the user tapped Claim *on this device*. A phone
 * holding the headset because something was playing still offered
 * "Claim Headset" - the symptom the issue was filed for.
 *
 * The fix is not "use the holder instead"; it is to notice the action is
 * answering two different questions and to let it answer only the one it
 * can act on:
 *
 * 1. **A manual claim is held** -> "Release Headset", enabled. Tapping
 *    ends it. True regardless of [holdsClaim], because a claim published
 *    but not yet granted is still the user's to cancel.
 * 2. **This node holds the headset, without a manual claim** -> a
 *    readout naming why, not tappable. Tapping *cannot* release it: a
 *    node can only end its own triggers, and the hold comes from
 *    `media`, `voip` or `call`, which end when the underlying activity
 *    does. Offering "Release Headset" would be a control that visibly
 *    does nothing; offering "Claim Headset" is the original bug.
 * 3. **Otherwise** -> "Claim Headset", enabled.
 *
 * Case 3 deliberately also covers a null [holdsClaim] - the relay has
 * not told us. Claiming is always a safe, meaningful action, so an
 * unknown holder degrades to the useful control rather than to a readout
 * that might be wrong.
 *
 * [because] is the trigger that started most recently, not the
 * highest-ranked one: adapters do not rank triggers (architecture.md
 * puts priority rules server-side, "never duplicated in adapters"), so
 * this reads insertion order and nothing else.
 */
fun claimAction(
    holdsClaim: Boolean?,
    manualClaimHeld: Boolean,
    because: EventKind? = null,
): ClaimAction {
    if (manualClaimHeld) return ClaimAction("Release Headset", isEnabled = true)
    if (holdsClaim == true) return ClaimAction(holdingTitle(because), isEnabled = false)
    return ClaimAction("Claim Headset", isEnabled = true)
}

/**
 * Present tense and specific, because the point of this line is to
 * answer "why is the headset here, and why can't I move it from here?"
 * in one glance.
 */
private fun holdingTitle(because: EventKind?): String =
    when (because) {
        EventKind.CALL -> "Holding — on a call"
        EventKind.VOIP -> "Holding — in a VoIP call"
        EventKind.MEDIA -> "Holding — playing media"
        // A manual claim is case 1 above and never reaches here. null is
        // a real state: the relay can make this node holder with no local
        // trigger active at all - it is the only node, say - and
        // inventing a reason would be worse than omitting one.
        EventKind.MANUAL_CLAIM, null -> "Holding headset"
    }
