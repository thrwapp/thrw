package com.thrw.adapter.android.triggers

/**
 * ADR 0010 point 1: after thrw initiates a claim or release, it
 * suppresses processing of its own resulting connection-state-changed
 * events for a short window, so it doesn't misread the side effects of
 * its own action as a new trigger.
 *
 * ## Why this became necessary
 *
 * Nothing needed it while the only triggers were `call` and `voip`:
 * telephony state and notification activity are unaffected by thrw's own
 * Bluetooth actions. The **media** triggers (#165/#166) broke that:
 *
 * - thrw disconnects the headset to hand it over, so
 * - audio on that device stops (macOS pauses playback when the output
 *   device disappears), so
 * - the media monitor observes "media ended", and
 * - thrw reports an `event_end` caused entirely by its own action.
 *
 * ## What this deliberately cannot do
 *
 * A time window is a heuristic, not a causal link. Inside the window this
 * cannot distinguish *"audio stopped because we disconnected the
 * headset"* from *"audio stopped because the user pressed pause at that
 * exact moment"* - both are suppressed. The second case means the relay
 * briefly believes a trigger is still active when it isn't; it corrects
 * on the next real state change.
 *
 * That is the trade ADR 0010 chose, and it is worth restating rather than
 * discovering later: **this can suppress genuine user actions that happen
 * to land within ~3s of a claim or release.**
 *
 * ## Scope
 *
 * This is ADR 0010 **point 1 only**. Points 2-5 of that ADR
 * (manual-override detection, scope limitation, known-conflict detection,
 * app-priority allowlist) are separate concerns and deliberately not
 * implemented here.
 *
 * Per ADR 0013 this is **not** a fifth connection state - it is
 * adapter-local bookkeeping layered around `onClaim`/`onRelease`, and
 * nothing in the frozen state machine changes.
 */
class SelfCooldown(
    private val windowMs: Long = DEFAULT_WINDOW_MS,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private var activeUntil = 0L

    /** Called immediately after thrw initiates a claim or release. */
    fun arm() {
        activeUntil = now() + windowMs
    }

    /** Whether trigger reporting should currently be suppressed. */
    fun isActive(): Boolean = now() < activeUntil

    companion object {
        /**
         * 6 seconds, per ADR 0010's 2026-09-23 amendment.
         *
         * `adapter-mac`'s `defaultSelfCooldown` is the same constant on
         * the other side of the same behaviour - change both together.
         *
         * **Was 3 seconds, which was too short (#251).** The old value
         * claimed to be "long enough to cover a Bluetooth profile
         * connect/disconnect and the audio stack settling afterwards".
         * It was not: ADR 0010 *estimated* ~3s, and ADR 0018 later
         * *measured* a claim taking 3-5s to move the route. The window
         * closed before the transition it exists to cover had finished,
         * and that transition's tail was read as a fresh trigger.
         *
         * On hardware, with media playing on both devices, the Mac
         * emitted `media` start/end pairs 1-5 seconds apart while
         * YouTube played continuously. Most-recently-started wins, so
         * each restart took the headset and each end gave it back -
         * bouncing indefinitely, with the relay arbitrating correctly
         * throughout.
         *
         * 6s covers ADR 0018's measured upper bound with margin and
         * stays clear of ADR 0019's 8s command bound. The "short enough
         * that a suppressed genuine action is rare" half of the old
         * reasoning is now carried by exempting `call` as well as
         * `manual_claim` - see [EventKind.bypassesSelfCooldown].
         */
        const val DEFAULT_WINDOW_MS = 6_000L
    }
}
