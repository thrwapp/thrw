package com.thrw.adapter.android.claim

import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.triggers.RecordingEventLifecycle
import com.thrw.adapter.android.triggers.TriggerCall
import com.thrw.adapter.android.triggers.UNRANKED_PRIORITY
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * #290. Test-for-test with `adapter-mac`'s `ArbitrationPauseTests` — the
 * two adapters must not diverge (criterion 7).
 */
class ArbitrationPauseTest {
    @Test
    fun `toggling on pauses`() = runTest {
        val pause = ArbitrationPause(RecordingEventLifecycle())

        assertTrue(pause.toggle())
        assertTrue(pause.isPaused())
    }

    @Test
    fun `toggling off resumes`() = runTest {
        val pause = ArbitrationPause(RecordingEventLifecycle())

        pause.toggle()

        assertFalse(pause.toggle())
        assertFalse(pause.isPaused())
    }

    /**
     * #290 criterion 2, and why suppressing future triggers is not
     * enough on its own: the relay counts what it was last told, so a
     * paused holder that only stopped *emitting* would keep the headset
     * until something else outranked it — exactly the situation the user
     * is trying to escape.
     */
    @Test
    fun `pausing ends the triggers this node had active`() = runTest {
        val node = RecordingEventLifecycle()
        node.emitEvent(EventKind.MEDIA, UNRANKED_PRIORITY)
        node.emitEvent(EventKind.VOIP, UNRANKED_PRIORITY)
        val pause = ArbitrationPause(node)

        pause.toggle()

        val ended = node.calls.filterIsInstance<TriggerCall.Ended>().map { it.kind }.toSet()
        assertEquals(setOf(EventKind.MEDIA, EventKind.VOIP), ended)
    }

    /**
     * Resuming must not re-assert anything. The triggers were ended on
     * the wire; whether they are still true is for the monitors to
     * report afresh, and inventing them here would publish a trigger for
     * something that may have stopped while paused.
     */
    @Test
    fun `resuming does not re-emit anything`() = runTest {
        val node = RecordingEventLifecycle()
        node.emitEvent(EventKind.MEDIA, UNRANKED_PRIORITY)
        val pause = ArbitrationPause(node)
        pause.toggle()
        val startedBefore = node.calls.filterIsInstance<TriggerCall.Started>().size

        pause.toggle()

        assertEquals(startedBefore, node.calls.filterIsInstance<TriggerCall.Started>().size)
    }

    @Test
    fun `pausing with nothing active ends nothing`() = runTest {
        val node = RecordingEventLifecycle()

        ArbitrationPause(node).toggle()

        assertTrue(node.calls.filterIsInstance<TriggerCall.Ended>().isEmpty())
    }

    /**
     * #290 criterion 3. The foreground service restarts with the
     * process, and a pause that quietly forgot itself would hand the
     * headset back mid-call — the failure it was turned on to prevent.
     */
    @Test
    fun `the state survives a new pause over the same store`() = runTest {
        val store = InMemoryArbitrationPauseStore()
        ArbitrationPause(RecordingEventLifecycle(), store).toggle()

        assertTrue(ArbitrationPause(RecordingEventLifecycle(), store).isPaused())
    }

    /** A fresh install must switch, not sit silently doing nothing. */
    @Test
    fun `an empty store is not paused`() {
        assertFalse(InMemoryArbitrationPauseStore().isPaused())
    }
}
