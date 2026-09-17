package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Fakes the [CallStateSource] boundary rather than mocking
 * `TelephonyManager`: this Gradle module has no `android.telephony` on its
 * classpath (see the source's kdoc), and the Gradle test runner can't raise
 * a real call state change either.
 */
private class FakeCallStateSource(private val states: List<PhoneCallState>) : CallStateSource {
    override fun callStates(): Flow<PhoneCallState> = states.asFlow()
}

class CallTriggerMonitorTest {
    @Test
    fun `an answered incoming call emits a call event on going offhook`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(
            FakeCallStateSource(listOf(PhoneCallState.RINGING, PhoneCallState.OFFHOOK)),
            node,
        )

        monitor.run()

        assertEquals(listOf<TriggerCall>(TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY)), node.calls)
    }

    @Test
    fun `an outgoing call emits a call event - offhook straight from idle`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(FakeCallStateSource(listOf(PhoneCallState.OFFHOOK)), node)

        monitor.run()

        assertEquals(listOf<TriggerCall>(TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY)), node.calls)
    }

    @Test
    fun `hanging up ends the call event`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(
            FakeCallStateSource(
                listOf(PhoneCallState.RINGING, PhoneCallState.OFFHOOK, PhoneCallState.IDLE),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.CALL),
            ),
            node.calls,
        )
    }

    @Test
    fun `a declined ringing call reports nothing at all - pre-claim is ADR 0011's job`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(
            FakeCallStateSource(listOf(PhoneCallState.RINGING, PhoneCallState.IDLE)),
            node,
        )

        monitor.run()

        assertTrue(node.calls.isEmpty())
    }

    @Test
    fun `repeated offhook does not re-emit, and repeated idle does not re-end`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(
            FakeCallStateSource(
                listOf(
                    PhoneCallState.IDLE,
                    PhoneCallState.OFFHOOK,
                    PhoneCallState.OFFHOOK,
                    PhoneCallState.IDLE,
                    PhoneCallState.IDLE,
                ),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.CALL),
            ),
            node.calls,
        )
    }

    @Test
    fun `call waiting mid-call neither ends the trigger nor starts a second one`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(
            FakeCallStateSource(
                listOf(
                    PhoneCallState.OFFHOOK,
                    // second call arrives while the first is still up
                    PhoneCallState.RINGING,
                    PhoneCallState.OFFHOOK,
                    PhoneCallState.IDLE,
                ),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.CALL),
            ),
            node.calls,
        )
    }

    @Test
    fun `two calls in a row are two start-end pairs`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(
            FakeCallStateSource(
                listOf(
                    PhoneCallState.OFFHOOK,
                    PhoneCallState.IDLE,
                    PhoneCallState.RINGING,
                    PhoneCallState.OFFHOOK,
                    PhoneCallState.IDLE,
                ),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.CALL),
                TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.CALL),
            ),
            node.calls,
        )
    }

    @Test
    fun `the reported priority is the unranked constant - adapters never rank`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(FakeCallStateSource(listOf(PhoneCallState.OFFHOOK)), node)

        monitor.run()

        val started = node.calls.single() as TriggerCall.Started
        assertEquals(UNRANKED_PRIORITY, started.priority)
    }

    @Test
    fun `a callback-driven caller can drive the monitor without a flow`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(FakeCallStateSource(emptyList()), node)

        monitor.onCallState(PhoneCallState.OFFHOOK)
        monitor.onCallState(PhoneCallState.IDLE)

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.CALL, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.CALL),
            ),
            node.calls,
        )
    }

    @Test
    fun `never reports media - out of scope for this issue`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = CallTriggerMonitor(
            FakeCallStateSource(
                listOf(PhoneCallState.RINGING, PhoneCallState.OFFHOOK, PhoneCallState.IDLE),
            ),
            node,
        )

        monitor.run()

        assertTrue(node.calls.none { it.kind == EventKind.MEDIA })
    }
}
