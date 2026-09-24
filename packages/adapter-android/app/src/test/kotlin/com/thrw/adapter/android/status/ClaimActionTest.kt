package com.thrw.adapter.android.status

import com.thrw.adapter.android.protocol.EventKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * #234. Test-for-test with `adapter-mac`'s `ClaimActionTests` - the two
 * adapters must not diverge (#234 criterion 6).
 *
 * The precedence between "the relay says we hold it" and "the user
 * tapped Claim here" is the whole decision, so it is tested as a pure
 * function - the same treatment [nodeStatus] gets, and for the same
 * reason: inside a `Notification.Builder` none of this is reachable from
 * a test.
 */
class ClaimActionTest {
    /**
     * The reported symptom, directly. A phone holding the headset
     * because something was playing used to offer "Claim Headset".
     */
    @Test
    fun `a node holding the headset does not offer to claim it`() {
        val action = claimAction(holdsClaim = true, manualClaimHeld = false, because = EventKind.MEDIA)

        assertNotEquals("Claim Headset", action.title)
        assertEquals("Holding — playing media", action.title)
        assertFalse(action.isEnabled, "a media hold cannot be released from here - see the kdoc")
    }

    @Test
    fun `each trigger names itself in the readout`() {
        assertEquals(
            "Holding — on a call",
            claimAction(holdsClaim = true, manualClaimHeld = false, because = EventKind.CALL).title,
        )
        assertEquals(
            "Holding — in a VoIP call",
            claimAction(holdsClaim = true, manualClaimHeld = false, because = EventKind.VOIP).title,
        )
    }

    /**
     * The relay can make this node holder with no local trigger active -
     * it is the only node, say. Inventing a reason would be worse than
     * omitting one.
     */
    @Test
    fun `holding with no known trigger still reads honestly`() {
        val action = claimAction(holdsClaim = true, manualClaimHeld = false, because = null)

        assertEquals("Holding headset", action.title)
        assertFalse(action.isEnabled)
    }

    @Test
    fun `a manual claim offers to release it`() {
        val action = claimAction(holdsClaim = true, manualClaimHeld = true, because = EventKind.MANUAL_CLAIM)

        assertEquals("Release Headset", action.title)
        assertTrue(action.isEnabled)
    }

    /**
     * A claim published but not yet granted is still the user's to
     * cancel, so the manual-claim branch deliberately does not consult
     * the holder.
     */
    @Test
    fun `a manual claim the relay has not granted yet is still releasable`() {
        val action = claimAction(holdsClaim = false, manualClaimHeld = true, because = EventKind.MANUAL_CLAIM)

        assertEquals("Release Headset", action.title)
        assertTrue(action.isEnabled)
    }

    @Test
    fun `not holding offers to claim`() {
        val action = claimAction(holdsClaim = false, manualClaimHeld = false, because = null)

        assertEquals("Claim Headset", action.title)
        assertTrue(action.isEnabled)
    }

    /**
     * An unknown holder degrades to the useful control, not to a readout
     * that might be wrong. Claiming is always safe and always meaningful.
     */
    @Test
    fun `an unknown holder still offers to claim`() {
        val action = claimAction(holdsClaim = null, manualClaimHeld = false, because = null)

        assertEquals("Claim Headset", action.title)
        assertTrue(action.isEnabled)
    }

    /**
     * #234's second symptom in miniature: before this, the label came
     * from the manual-claim flag alone, so these two inputs produced the
     * same answer. They must not.
     */
    @Test
    fun `holding and not holding differ without a manual claim`() {
        val holding = claimAction(holdsClaim = true, manualClaimHeld = false, because = EventKind.MEDIA)
        val notHolding = claimAction(holdsClaim = false, manualClaimHeld = false, because = null)

        assertNotEquals(holding, notHolding)
    }
}
