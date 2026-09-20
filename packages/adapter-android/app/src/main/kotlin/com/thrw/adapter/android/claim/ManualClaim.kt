package com.thrw.adapter.android.claim

import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.triggers.EventLifecycle
import com.thrw.adapter.android.triggers.UNRANKED_PRIORITY

/**
 * The user's own "put the headset here" (#212).
 *
 * `manual_claim` sits second in `PRIORITY_ORDER` - below a call, above
 * VoIP and media - and until now nothing emitted it. ADR 0010's
 * principle is that direct user action always wins; this is what makes
 * that true rather than aspirational. Mirrors `adapter-mac`'s
 * `ManualClaim`.
 *
 * ## Why it is a toggle, and why it persists
 *
 * The obvious design - emit the event, let the relay claim, then end it
 * immediately - does not work, and the failure is quiet enough to be
 * worth recording.
 *
 * Ending the event makes the engine recompute the holder from whatever
 * is *still* active. If the Mac is playing media and you manual-claim on
 * the phone, the phone wins on rank, then ends its event, and
 * `computeActiveHolder` hands the headset straight back to the Mac's
 * still-active `media`. The user's action would be undone within a
 * second.
 *
 * So the claim persists until it is released, until another node
 * manual-claims (both have it active, and most-recently-started wins,
 * which is the right answer), or until a call outranks it. Media
 * elsewhere deliberately cannot take it back - that is the point of
 * having the control at all.
 */
class ManualClaim(private val node: EventLifecycle) {
    private val lock = Any()
    private var held = false

    /** Whether this node is currently holding a manual claim. */
    fun isHeld(): Boolean = synchronized(lock) { held }

    /**
     * Claims if not held, releases if held. Returns the new state.
     *
     * The local flag is updated **only after** the publish succeeds. If
     * the relay cannot be reached the UI keeps showing the truth rather
     * than a state the relay never heard about, and the next tap retries
     * rather than toggling into a lie.
     */
    suspend fun toggle(): Boolean {
        val wantToHold = !isHeld()
        if (wantToHold) {
            node.emitEvent(EventKind.MANUAL_CLAIM, UNRANKED_PRIORITY)
        } else {
            node.endEvent(EventKind.MANUAL_CLAIM)
        }
        synchronized(lock) { held = wantToHold }
        return wantToHold
    }
}
