package com.thrw.adapter.android.bluetooth

import android.bluetooth.BluetoothProfile
import kotlin.test.Test
import kotlin.test.assertEquals

private const val DISCONNECTED = BluetoothProfile.STATE_DISCONNECTED
private const val CONNECTING = BluetoothProfile.STATE_CONNECTING
private const val CONNECTED = BluetoothProfile.STATE_CONNECTED

/**
 * #264. `AndroidBluetoothClassicGateway` needs real `android.bluetooth`
 * proxies and has no unit tests; this is where its only interesting
 * judgement lives, so this is what gets tested.
 */
class ProfileWaitDecisionTest {
    @Test
    fun `a profile at the target state is reached`() {
        assertEquals(
            ProfileWaitDecision.REACHED,
            profileWaitDecision(listOf(CONNECTED), CONNECTED, sawConnecting = true, elapsedMs = 0),
        )
    }

    /**
     * Only one has to get there - a headset that is call-only has no
     * A2DP, and failing the whole claim for that would be wrong (#257).
     */
    @Test
    fun `one profile reaching the target is enough`() {
        assertEquals(
            ProfileWaitDecision.REACHED,
            profileWaitDecision(
                listOf(CONNECTED, DISCONNECTED),
                CONNECTED,
                sawConnecting = true,
                elapsedMs = 0,
            ),
        )
    }

    /** #257's refusal: accepted, then dropped back. */
    @Test
    fun `back to disconnected after connecting is a refusal`() {
        assertEquals(
            ProfileWaitDecision.REFUSED,
            profileWaitDecision(listOf(DISCONNECTED), CONNECTED, sawConnecting = true, elapsedMs = 50),
        )
    }

    /**
     * A refusal is known immediately and needs no timer - it must not
     * wait out [UNREACHABLE_AFTER_MS] first.
     */
    @Test
    fun `a refusal does not wait for the unreachable threshold`() {
        assertEquals(
            ProfileWaitDecision.REFUSED,
            profileWaitDecision(listOf(DISCONNECTED), CONNECTED, sawConnecting = true, elapsedMs = 0),
        )
    }

    // ---- the actual bug (#264) ----

    /**
     * The reported case: headphones in their case. The profile never
     * reaches CONNECTING at all, so #257's refusal detection never
     * fires, and before this the poll ran to the outer 8s bound and
     * reported `timed_out`.
     */
    @Test
    fun `never leaving disconnected is unreachable once the threshold passes`() {
        assertEquals(
            ProfileWaitDecision.UNREACHABLE,
            profileWaitDecision(
                listOf(DISCONNECTED),
                CONNECTED,
                sawConnecting = false,
                elapsedMs = UNREACHABLE_AFTER_MS,
            ),
        )
    }

    /**
     * Criterion 3, and the failure that would be worse than the bug:
     * DISCONNECTED is legitimately the state for a moment right after
     * the request is accepted, so a working connect must not be called
     * unreachable while it is still starting.
     */
    @Test
    fun `still disconnected before the threshold keeps waiting`() {
        assertEquals(
            ProfileWaitDecision.KEEP_WAITING,
            profileWaitDecision(
                listOf(DISCONNECTED),
                CONNECTED,
                sawConnecting = false,
                elapsedMs = UNREACHABLE_AFTER_MS - 1,
            ),
        )
    }

    /**
     * The other half of criterion 3. A slow-but-working connect has
     * reached CONNECTING, so the unreachable path must never apply to
     * it however long it takes - the outer 8s bound owns that case, and
     * calling it unreachable would turn a working switch into a
     * reported failure.
     */
    @Test
    fun `a connect still in progress is never unreachable however long it takes`() {
        assertEquals(
            ProfileWaitDecision.KEEP_WAITING,
            profileWaitDecision(
                listOf(CONNECTING),
                CONNECTED,
                sawConnecting = true,
                elapsedMs = UNREACHABLE_AFTER_MS * 10,
            ),
        )
    }

    /**
     * The threshold must comfortably clear the measured claim: ~4.9s end
     * to end, of which <1s is relay delivery (#254). This is not a
     * tautology - it is the assertion that fails if someone raises the
     * threshold past the point where it stops saving anything, or drops
     * it into the range a healthy connect occupies.
     */
    @Test
    fun `the unreachable threshold sits below the outer bound and above the poll interval`() {
        assertEquals(
            true,
            UNREACHABLE_AFTER_MS < 8_000L,
            "must resolve faster than #244's bound, or it saves nothing (criterion 2)",
        )
        assertEquals(
            true,
            UNREACHABLE_AFTER_MS >= 1_000L,
            "must leave room for a stack that is slow to accept, or a working switch reports failed",
        )
    }

    // ---- the disconnect path is untouched ----

    /**
     * Neither refusal nor unreachability is meaningful while waiting for
     * DISCONNECTED: a disconnect that has not got there yet is simply
     * still in progress, and the outer bound owns how long that may
     * take.
     */
    @Test
    fun `a disconnect that has not finished just keeps waiting`() {
        assertEquals(
            ProfileWaitDecision.KEEP_WAITING,
            profileWaitDecision(
                listOf(CONNECTED),
                DISCONNECTED,
                sawConnecting = false,
                elapsedMs = UNREACHABLE_AFTER_MS * 10,
            ),
        )
    }

    @Test
    fun `a disconnect that reached disconnected is done`() {
        assertEquals(
            ProfileWaitDecision.REACHED,
            profileWaitDecision(listOf(DISCONNECTED), DISCONNECTED, sawConnecting = false, elapsedMs = 0),
        )
    }
}
