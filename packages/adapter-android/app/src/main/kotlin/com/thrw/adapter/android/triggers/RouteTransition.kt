package com.thrw.adapter.android.triggers

/**
 * Tracks whether a claim or release is still settling, so route
 * observations taken mid-transition are not reported as fact (#191, ADR
 * 0018 decision 2).
 *
 * Moving the audio route is not instantaneous. Measured on the reference
 * hardware, a claim takes **3-5 seconds** for the headset to actually
 * become the active output. A reconciliation snapshot inside that window
 * reports "I do not hold this" while the relay correctly believes the
 * node does - and the relay, seeing a disagreement, would issue a
 * corrective command for a transition that was simply still happening.
 * On a 2-minute cadence that is a permanent oscillation generator.
 *
 * ## Why not reuse [SelfCooldown]
 *
 * It answers a different question and its window is load-bearing at its
 * current value. The cooldown suppresses *triggers* caused by thrw's own
 * action, and its 3 seconds is what stops a released device re-claiming
 * on its own continuing audio - verified on hardware. The claim side
 * settles later than that (the media monitor was observed re-firing at
 * +4s and +5s, outside the cooldown), so widening the cooldown to cover
 * route settling would change behaviour that is already correct.
 */
class RouteTransition(
    private val settleMs: Long = DEFAULT_SETTLE_MS,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val lock = Any()
    private var inProgress = 0
    private var settledAt = Long.MIN_VALUE

    /** A claim or release has started. */
    fun begin() = synchronized(lock) { inProgress += 1 }

    /** It finished - the route may still be catching up for [settleMs]. */
    fun end() = synchronized(lock) {
        if (inProgress > 0) inProgress -= 1
        settledAt = now() + settleMs
    }

    /**
     * True while a transition is running *or* still settling. A route
     * observation taken now means nothing and must be omitted rather than
     * reported.
     */
    fun isSettling(): Boolean = synchronized(lock) { inProgress > 0 || now() < settledAt }

    companion object {
        /**
         * Six seconds: comfortably past the 3-5s settle measured on the
         * reference hardware, without being so long that a node stays
         * unreconcilable for a meaningful slice of the 2-minute
         * registration cadence.
         *
         * Derived from measurement rather than chosen - see
         * `docs/testing/compatibility-matrix.md`. `adapter-mac`'s
         * `defaultRouteSettle` is the same constant on the other side.
         */
        const val DEFAULT_SETTLE_MS = 6_000L
    }
}
