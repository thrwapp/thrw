package com.thrw.adapter.android.status

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Who the relay says holds this resource, as last seen on the retained
 * state topic (#234). Kotlin mirror of `adapter-mac`'s `HolderState`.
 *
 * ## Why this exists at all
 *
 * Before #234 nothing in either adapter read relay state. The
 * notification's action label came from [com.thrw.adapter.android.claim.ManualClaim]'s
 * own boolean, written only when the user taps - so it answered *"did
 * you tap Claim on this device?"*, never *"does this device hold the
 * headset?"* A node holding via a `call`, `voip` or `media` trigger
 * still offered "Claim Headset", which is the symptom #234 was filed
 * for.
 *
 * The answer was already on the broker. #229 made the relay publish it
 * retained, so a subscriber is sent the current holder immediately on
 * subscribe rather than waiting for the next change - which matters for
 * a service that may start long after the last handover.
 *
 * ## Three states, not two
 *
 * [Holder.Unknown] means **we have not heard**, and it is deliberately
 * distinct from somebody else holding it:
 *
 * - Never subscribed, or subscribed and no retained message existed yet
 *   (a fresh account that has never had a holder).
 * - The transport is down, so what we last heard may be arbitrarily
 *   stale.
 *
 * Collapsing that into `false` would make the notification assert
 * something it does not know - the failure [NodeStatus] already refuses
 * to commit, its `Unknown` case existing for exactly this reason.
 *
 * ## Why a StateFlow
 *
 * #234 criterion 4: the Android notification has to be re-posted when
 * holder state *changes*, not only when the user toggles a claim or the
 * runtime starts. A flow gives that without a timer - see
 * `AdapterForegroundService`'s own note on why a timer was rejected.
 */
class HolderState {
    /** The relay's answer, or [Holder.Unknown] if it has not given one. */
    sealed interface Holder {
        data object Unknown : Holder

        /** [nodeId] is null when the relay says nobody holds it. */
        data class Known(val nodeId: String?) : Holder
    }

    private val _holder = MutableStateFlow<Holder>(Holder.Unknown)

    /**
     * Emits on every change, and replays the current value to a new
     * collector - so a collector that starts late is correct
     * immediately rather than after the next handover.
     */
    val holder: StateFlow<Holder> = _holder.asStateFlow()

    /**
     * A retained state message arrived. [nodeId] may legitimately be
     * null: that is the relay saying nobody holds this resource.
     */
    fun update(nodeId: String?) {
        _holder.value = Holder.Known(nodeId)
    }

    /**
     * Whether [nodeId] is the current holder, or null if the relay has
     * not told us.
     */
    fun holds(nodeId: String): Boolean? =
        when (val current = _holder.value) {
            is Holder.Unknown -> null
            is Holder.Known -> current.nodeId == nodeId
        }

    /**
     * Forgets what we were told, returning to [Holder.Unknown].
     *
     * Called when the transport drops (#182): a retained value received
     * before a disconnect says what was true then, and the whole point
     * of the unknown state is to avoid presenting a stale belief as
     * current.
     */
    fun forget() {
        _holder.value = Holder.Unknown
    }
}
