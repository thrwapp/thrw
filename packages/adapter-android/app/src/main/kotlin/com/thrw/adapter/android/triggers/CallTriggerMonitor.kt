package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind

/**
 * Turns `TelephonyManager` call state (via [CallStateSource]) into the
 * node's `call` trigger - architecture.md's rule 1, "incoming / outgoing
 * phone call - always wins".
 *
 * The mapping:
 *
 * | state seen                  | reported                                  |
 * |-----------------------------|-------------------------------------------|
 * | [PhoneCallState.OFFHOOK]    | `emitEvent("call", ...)`, if not already  |
 * | [PhoneCallState.IDLE]       | `endEvent("call")`, if one was emitted    |
 * | [PhoneCallState.RINGING]    | nothing (see below)                       |
 *
 * **Why ringing reports nothing.** `OFFHOOK` is the state the platform
 * uses for an answered incoming call *and* for an outgoing call the moment
 * it's dialed, so it covers both halves of rule 1 and is the point at
 * which the headset is actually needed. `RINGING` is a *prediction* that a
 * call is about to start, and ADR 0011 is explicit about where that
 * belongs: ringing is the pre-claim trigger, and pre-claim is a state in
 * the connection state machine - a frozen contract per ADR
 * 0010/0011/0013, needing its own ADR and human review. Emitting a full
 * `call` event on ringing would do that state machine's job badly instead:
 * a declined or missed call would take the headset (rule 1 beats
 * everything) and then hand it back, which is the visible flicker ADR 0011
 * exists to avoid. So [CallStateSource] surfaces `RINGING` - the signal is
 * there for the pre-claim work - and this monitor deliberately drops it.
 *
 * Ignoring `RINGING` also means call waiting behaves: a second call
 * arriving mid-call (`OFFHOOK` -> `RINGING` -> `OFFHOOK`) neither ends the
 * trigger that's already open nor starts a second one, because only `IDLE`
 * closes it.
 *
 * No state machine here: this holds one boolean - whether a `call` trigger
 * is currently open - purely so starts and ends pair up. It makes no
 * claim/release decision (the relay does) and tracks no node state.
 */
class CallTriggerMonitor(
    private val source: CallStateSource,
    private val node: EventLifecycle,
) {
    private var callOpen = false

    /**
     * Collects call states and reports trigger start/end. Suspends until
     * the source's flow completes or the calling coroutine is cancelled.
     */
    suspend fun run() {
        source.callStates().collect { state -> onCallState(state) }
    }

    /**
     * Handles one call-state change. Exposed separately from [run] so a
     * caller already holding a `TelephonyCallback` (or a test) can drive it
     * directly.
     */
    suspend fun onCallState(state: PhoneCallState) {
        when (state) {
            PhoneCallState.OFFHOOK ->
                if (!callOpen) {
                    callOpen = true
                    node.emitEvent(EventKind.CALL, UNRANKED_PRIORITY)
                }

            PhoneCallState.IDLE ->
                if (callOpen) {
                    callOpen = false
                    node.endEvent(EventKind.CALL)
                }

            PhoneCallState.RINGING -> Unit
        }
    }
}
