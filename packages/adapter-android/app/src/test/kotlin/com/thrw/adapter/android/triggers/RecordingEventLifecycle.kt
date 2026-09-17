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

    override suspend fun emitEvent(type: EventKind, priority: Priority) {
        calls += TriggerCall.Started(type, priority)
    }

    override suspend fun endEvent(type: EventKind) {
        calls += TriggerCall.Ended(type)
    }
}
