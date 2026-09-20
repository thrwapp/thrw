package com.thrw.adapter.android.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * ADR 0018 decision 1 (#210), adapter half.
 *
 * Every test here names a delivery the broker is actually entitled to
 * make - QoS 1 is at-least-once - rather than an abstract ordering
 * property.
 */
class CommandSequenceGateTest {
    private fun claim(seq: Long?, epoch: String?) = CommandPayload(CommandType.CLAIM, seq, epoch)

    private fun release(seq: Long?, epoch: String?) = CommandPayload(CommandType.RELEASE, seq, epoch)

    @Test
    fun `accepts the first command it ever sees`() {
        val gate = CommandSequenceGate()

        assertTrue(gate.accepts(claim(1, "e1")))
    }

    @Test
    fun `accepts a command newer than the mark`() {
        val gate = CommandSequenceGate()
        gate.record(claim(1, "e1"))

        assertTrue(gate.accepts(release(2, "e1")))
    }

    /**
     * The failure ADR 0018 names by hand: *"a stale claim arriving after
     * a more recent release must not re-claim"*. Without the gate this
     * takes the headset back from whichever device now holds it.
     */
    @Test
    fun `discards a claim redelivered after a newer release`() {
        val gate = CommandSequenceGate()
        gate.record(claim(4, "e1"))
        gate.record(release(5, "e1"))

        assertFalse(gate.accepts(claim(4, "e1")))
    }

    @Test
    fun `discards an exact duplicate`() {
        val gate = CommandSequenceGate()
        gate.record(claim(7, "e1"))

        assertFalse(gate.accepts(claim(7, "e1")))
    }

    /**
     * Rule 2. Without this the system deadlocks after any relay restart:
     * the relay's counters are in memory and go back to zero, while this
     * node still holds a mark in the thousands.
     */
    @Test
    fun `a new epoch resets the mark`() {
        val gate = CommandSequenceGate()
        gate.record(claim(9_999, "e1"))

        assertTrue(gate.accepts(claim(1, "e2")))
    }

    @Test
    fun `after an epoch change the new epoch's own ordering applies`() {
        val gate = CommandSequenceGate()
        gate.record(claim(9_999, "e1"))
        gate.record(claim(1, "e2"))

        assertFalse(gate.accepts(claim(1, "e2")))
        assertTrue(gate.accepts(release(2, "e2")))
    }

    /**
     * An epoch the node saw two epochs ago is not special-cased: the
     * mark holds exactly one epoch, and anything not equal to it resets.
     * Ordering across relay processes is not defined, so there is
     * nothing better to do than trust the newest sender.
     */
    @Test
    fun `returning to a previously seen epoch also resets`() {
        val gate = CommandSequenceGate()
        gate.record(claim(5, "e1"))
        gate.record(claim(5, "e2"))

        assertTrue(gate.accepts(claim(1, "e1")))
    }

    @Test
    fun `an unsequenced command is accepted and records nothing`() {
        val store = InMemorySequenceStore()
        val gate = CommandSequenceGate(store)

        assertTrue(gate.accepts(claim(null, null)))
        gate.record(claim(null, null))

        assertNull(store.load(RESOURCE_AUDIO))
    }

    @Test
    fun `a command with a seq but no epoch is accepted rather than compared`() {
        val gate = CommandSequenceGate()
        gate.record(claim(50, "e1"))

        assertTrue(gate.accepts(claim(1, null)))
    }

    @Test
    fun `an unsequenced command does not erase an existing mark`() {
        val store = InMemorySequenceStore()
        val gate = CommandSequenceGate(store)
        gate.record(claim(50, "e1"))

        gate.record(claim(null, null))

        assertEquals(SequenceMark("e1", 50), store.load(RESOURCE_AUDIO))
    }

    /**
     * `record` never moves the mark backwards, even if called with an
     * older command. Nothing in `listenForCommands` does that today -
     * `accepts` guards it - but the two are separate calls, and a mark
     * that could be dragged back by a mis-sequenced call site would
     * reopen the whole hole.
     */
    @Test
    fun `record does not move the mark backwards`() {
        val store = InMemorySequenceStore()
        val gate = CommandSequenceGate(store)
        gate.record(claim(9, "e1"))

        gate.record(claim(3, "e1"))

        assertEquals(SequenceMark("e1", 9), store.load(RESOURCE_AUDIO))
    }

    @Test
    fun `accepts does not move the mark`() {
        val store = InMemorySequenceStore()
        val gate = CommandSequenceGate(store)
        gate.record(claim(2, "e1"))

        assertTrue(gate.accepts(claim(3, "e1")))
        assertTrue(gate.accepts(claim(3, "e1")))
        assertEquals(SequenceMark("e1", 2), store.load(RESOURCE_AUDIO))
    }

    /**
     * Acceptance criterion 3. Two gates over one store is precisely what
     * a process restart looks like from the store's point of view.
     */
    @Test
    fun `the mark survives a process restart`() {
        val store = InMemorySequenceStore()
        CommandSequenceGate(store).record(claim(11, "e1"))

        val afterRestart = CommandSequenceGate(store)

        assertFalse(afterRestart.accepts(claim(11, "e1")))
        assertTrue(afterRestart.accepts(claim(12, "e1")))
    }

    /**
     * Acceptance criterion 4, half one: **this node** restarted while
     * holding. The relay is the same process, so its counter kept
     * climbing while the node was away, and the claim #173 re-asserts on
     * registration carries a higher seq than the persisted mark.
     *
     * If this ever fails, #173 has regressed silently: a device that
     * restarts while holding the headset goes back to being permanently
     * stuck, with no command on the wire to show why.
     */
    @Test
    fun `173's re-asserted claim is accepted after the node restarts`() {
        val store = InMemorySequenceStore()
        CommandSequenceGate(store).record(claim(6, "e1"))

        val afterRestart = CommandSequenceGate(store)

        assertTrue(afterRestart.accepts(claim(7, "e1")))
    }

    /**
     * Acceptance criterion 4, half two: **the relay** restarted. Its
     * counter is back at 1, far below this node's mark - and is accepted
     * anyway, because the epoch changed. This is the case that would
     * deadlock without the epoch.
     */
    @Test
    fun `173's re-asserted claim is accepted after the relay restarts`() {
        val store = InMemorySequenceStore()
        CommandSequenceGate(store).record(claim(431, "e1"))

        assertTrue(CommandSequenceGate(store).accepts(claim(1, "e2")))
    }

    /**
     * Two resource types are two independent counters relay-side (ADR
     * 0015 / ADR 0018), so they must be two independent marks here. Only
     * `audio` exists today; a shared mark would break the day `hid`
     * arrives, in a way that looks like dropped commands.
     */
    @Test
    fun `resources keep independent marks`() {
        val store = InMemorySequenceStore()
        val audio = CommandSequenceGate(store, "audio")
        val hid = CommandSequenceGate(store, "hid")
        audio.record(claim(40, "e1"))

        assertTrue(hid.accepts(claim(1, "e1")))
        assertFalse(audio.accepts(claim(1, "e1")))
    }
}
