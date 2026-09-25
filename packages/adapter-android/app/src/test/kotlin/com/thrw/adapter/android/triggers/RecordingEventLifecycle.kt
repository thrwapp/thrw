package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.Priority

/** One reported trigger transition, in order, for the monitor tests. */
sealed interface TriggerCall {
    val kind: EventKind

    data class Started(override val kind: EventKind, val priority: Priority) : TriggerCall

    data class Ended(override val kind: EventKind) : TriggerCall
}

/**
 * Records what a monitor reported to its node. Shared by
 * `CallTriggerMonitorTest` and `VoipTriggerMonitorTest`; that the calls
 * actually reach MQTT is `AndroidNodeTest`'s job.
 */
class RecordingEventLifecycle : EventLifecycle {
    val calls = mutableListOf<TriggerCall>()

    /**
     * #234. Mirrors `AndroidNode`'s own `activeEvents` closely enough
     * for `ManualClaim` to be tested against it: a trigger is active
     * from a successful `emitEvent` until an `endEvent`. A
     * `LinkedHashSet` for the same reason the node uses one - insertion
     * order is what `mostRecentTrigger()` reads.
     */
    private val active = linkedSetOf<EventKind>()

    override suspend fun emitEvent(type: EventKind, priority: Priority) {
        calls += TriggerCall.Started(type, priority)
        active += type
    }

    override suspend fun endEvent(type: EventKind) {
        calls += TriggerCall.Ended(type)
        active -= type
    }

    override fun isEventActive(type: EventKind): Boolean = active.contains(type)

    override fun activeEventKinds(): List<EventKind> = active.toList()
}
