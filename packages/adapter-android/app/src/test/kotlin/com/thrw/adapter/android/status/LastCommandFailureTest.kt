package com.thrw.adapter.android.status

import com.thrw.adapter.android.protocol.CommandFailureReason
import com.thrw.adapter.android.protocol.CommandOutcome
import com.thrw.adapter.android.protocol.CommandType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * #309 / scenarios.md R3. Before this, a command that failed reached
 * `Log.e` and stopped there, so a claim the user made and a claim that
 * silently never happened looked identical on screen.
 */
class LastCommandFailureTest {
    private val res = NotificationTextResources(
        claimFailed = 1,
        commandFailedUnreachable = 2,
        commandFailedNoResponse = 3,
        commandFailedBluetooth = 4,
        commandFailedRelease = 5,
    )

    private fun failure(
        type: CommandType = CommandType.CLAIM,
        outcome: CommandOutcome = CommandOutcome.FAILED,
        reason: CommandFailureReason? = null,
    ) = CommandFailure(type, outcome, reason)

    @Test
    fun `starts with nothing to report`() {
        assertNull(LastCommandFailure().current())
    }

    @Test
    fun `records the most recent failure`() {
        val store = LastCommandFailure()
        store.record(failure(reason = CommandFailureReason.TARGET_DEVICE_UNREACHABLE))
        assertEquals(CommandFailureReason.TARGET_DEVICE_UNREACHABLE, store.current()?.reason)
    }

    // The whole point of clearing on success rather than on a timer: a
    // notice that expired on a clock would claim things are fine while
    // they are still broken.
    @Test
    fun `a success clears it`() {
        val store = LastCommandFailure()
        store.record(failure())
        store.clear()
        assertNull(store.current())
    }

    @Test
    fun `a later failure replaces an earlier one`() {
        val store = LastCommandFailure()
        store.record(failure(reason = CommandFailureReason.BLUETOOTH_UNAVAILABLE))
        store.record(failure(outcome = CommandOutcome.TIMED_OUT))
        assertEquals(CommandOutcome.TIMED_OUT, store.current()?.outcome)
    }

    // --- notificationTextRes: the precedence is the decision here ---

    @Test
    fun `a failed tap outranks everything - the user just acted`() {
        assertEquals(
            res.claimFailed,
            notificationTextRes(
                claimFailed = true,
                failure = failure(reason = CommandFailureReason.TARGET_DEVICE_UNREACHABLE),
                statusRes = 99,
                defaultRes = 98,
                res = res,
            ),
        )
    }

    // R3's own wording: headset in its case or out of range.
    @Test
    fun `an unreachable headset is named as something the user can act on`() {
        assertEquals(
            res.commandFailedUnreachable,
            notificationTextRes(
                claimFailed = false,
                failure = failure(reason = CommandFailureReason.TARGET_DEVICE_UNREACHABLE),
                statusRes = 99,
                defaultRes = 98,
                res = res,
            ),
        )
    }

    @Test
    fun `a timeout is distinct from a refusal`() {
        assertEquals(
            res.commandFailedNoResponse,
            notificationTextRes(
                claimFailed = false,
                failure = failure(outcome = CommandOutcome.TIMED_OUT),
                statusRes = 99,
                defaultRes = 98,
                res = res,
            ),
        )
    }

    @Test
    fun `bluetooth being unavailable is its own message`() {
        assertEquals(
            res.commandFailedBluetooth,
            notificationTextRes(
                claimFailed = false,
                failure = failure(reason = CommandFailureReason.BLUETOOTH_UNAVAILABLE),
                statusRes = 99,
                defaultRes = 98,
                res = res,
            ),
        )
    }

    /**
     * ADR 0019 tracks `superseded_by_newer_command` separately from real
     * failures because it is idempotency working correctly. Reporting it
     * to the user would alarm them about normal operation.
     *
     * Neither adapter records it as a failure today — both guards return
     * before the record — so this pins the defensive behaviour rather
     * than a reachable path.
     */
    @Test
    fun `a superseded command is not a failure the user hears about`() {
        assertEquals(
            99,
            notificationTextRes(
                claimFailed = false,
                failure = failure(reason = CommandFailureReason.SUPERSEDED_BY_NEWER_COMMAND),
                statusRes = 99,
                defaultRes = 98,
                res = res,
            ),
        )
    }

    @Test
    fun `with nothing wrong the ordinary status line shows`() {
        assertEquals(
            99,
            notificationTextRes(
                claimFailed = false,
                failure = null,
                statusRes = 99,
                defaultRes = 98,
                res = res,
            ),
        )
    }

    @Test
    fun `falls back to the default when there is no status yet`() {
        assertEquals(
            98,
            notificationTextRes(
                claimFailed = false,
                failure = null,
                statusRes = null,
                defaultRes = 98,
                res = res,
            ),
        )
    }
}
