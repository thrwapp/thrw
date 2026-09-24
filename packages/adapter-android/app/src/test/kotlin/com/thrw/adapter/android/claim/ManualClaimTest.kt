package com.thrw.adapter.android.claim

import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.triggers.EventLifecycle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private class Recording : EventLifecycle {
    val emitted = mutableListOf<EventKind>()
    val ended = mutableListOf<EventKind>()

    /** #234 - see `RecordingEventLifecycle` for why this models the set. */
    private val active = linkedSetOf<EventKind>()

    override suspend fun emitEvent(type: EventKind, priority: Int) {
        emitted += type
        active += type
    }

    override suspend fun endEvent(type: EventKind) {
        ended += type
        active -= type
    }

    override fun isEventActive(type: EventKind): Boolean = active.contains(type)
}

/** Fails every publish, to check local state does not drift from what the relay was told. */
private class Failing : EventLifecycle {
    override suspend fun emitEvent(type: EventKind, priority: Int) = throw IllegalStateException("boom")
    override suspend fun endEvent(type: EventKind) = throw IllegalStateException("boom")

    /** Nothing ever succeeded, so nothing is ever active. */
    override fun isEventActive(type: EventKind): Boolean = false
}

class ManualClaimTest {
    @Test
    fun `toggling on emits a manual claim`() = runTest {
        val node = Recording()
        val claim = ManualClaim(node)

        assertTrue(claim.toggle())

        assertEquals(listOf(EventKind.MANUAL_CLAIM), node.emitted)
        assertTrue(node.ended.isEmpty(), "claiming must not also end it - see the kdoc")
    }

    @Test
    fun `toggling off ends it`() = runTest {
        val node = Recording()
        val claim = ManualClaim(node)

        claim.toggle()
        assertFalse(claim.toggle())

        assertEquals(listOf(EventKind.MANUAL_CLAIM), node.ended)
    }

    /**
     * The claim has to persist, or the engine recomputes the holder from
     * whatever is still active elsewhere and undoes the user's action.
     */
    @Test
    fun `the claim is not ended immediately after being made`() = runTest {
        val node = Recording()
        val claim = ManualClaim(node)

        claim.toggle()

        assertTrue(claim.isHeld())
        assertTrue(node.ended.isEmpty())
    }

    /**
     * If the relay could not be told, the UI must not start claiming the
     * headset is held - the next tap should retry, not toggle into a
     * state that only exists on the device.
     */
    @Test
    fun `a failed publish leaves the state unchanged`() = runTest {
        val claim = ManualClaim(Failing())

        assertFailsWith<IllegalStateException> { claim.toggle() }

        assertFalse(claim.isHeld(), "a failed claim must not be recorded as held")
    }
}
