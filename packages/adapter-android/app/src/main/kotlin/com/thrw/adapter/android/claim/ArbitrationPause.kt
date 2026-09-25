package com.thrw.adapter.android.claim

import android.content.Context
import com.thrw.adapter.android.triggers.EventLifecycle

/**
 * Where the paused flag survives a restart (#290).
 *
 * An interface rather than `SharedPreferences` directly, the same seam
 * `CommandSequenceGate`'s store uses, so the pause logic is testable
 * without an Android context.
 */
interface ArbitrationPauseStore {
    fun isPaused(): Boolean

    fun setPaused(paused: Boolean)
}

/** For tests, and for a node built without persistence. */
class InMemoryArbitrationPauseStore(private var paused: Boolean = false) : ArbitrationPauseStore {
    private val lock = Any()

    override fun isPaused(): Boolean = synchronized(lock) { paused }

    override fun setPaused(paused: Boolean) {
        synchronized(lock) { this.paused = paused }
    }
}

/**
 * [ArbitrationPauseStore] backed by `SharedPreferences`.
 *
 * Durable because the situation it exists for outlasts the process
 * (#290 criterion 3): the foreground service restarts with the process,
 * and a pause that quietly forgot itself would hand the headset back
 * mid-call — the exact failure it was turned on to prevent.
 */
class SharedPreferencesArbitrationPauseStore(context: Context) : ArbitrationPauseStore {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun isPaused(): Boolean = prefs.getBoolean(KEY, false)

    override fun setPaused(paused: Boolean) {
        prefs.edit().putBoolean(KEY, paused).apply()
    }

    private companion object {
        const val PREFS = "thrw_adapter"
        const val KEY = "arbitration_paused"
    }
}

/**
 * "Leave my headset alone on this device" (#290). Kotlin mirror of
 * `adapter-mac`'s `ArbitrationPause` — the two must not diverge.
 *
 * ## Why this exists
 *
 * thrw arbitrates between the devices it manages. A device without an
 * adapter — a locked-down work laptop, most commonly — is invisible to
 * it, so a trigger on a managed device wins against a call happening on
 * the unmanaged one. #287 is that, reported from real use: this phone
 * taking the headset off a laptop call, repeatedly.
 *
 * #289 bounded the repetition. It cannot stop the first claim, because
 * from the relay's point of view nothing else is using the headset. This
 * is the escape hatch: the user knows they are on a call even when thrw
 * structurally cannot.
 *
 * ## Why suppressing emission is enough
 *
 * A paused node publishes no triggers, so it has nothing to win
 * arbitration with and the relay has no reason to claim it. Commands are
 * still honoured — pausing means "stop grabbing", not "go deaf".
 *
 * The tempting alternative, ignoring commands, is wrong: it leaves the
 * relay believing this node holds a resource it does not, which is the
 * drift #287 was about. Better not to manufacture that state on purpose.
 */
class ArbitrationPause(
    private val node: EventLifecycle,
    private val store: ArbitrationPauseStore = InMemoryArbitrationPauseStore(),
) {
    fun isPaused(): Boolean = store.isPaused()

    /**
     * Pauses if running, resumes if paused. Returns the new state.
     *
     * Pausing **ends this node's active triggers**, published, rather
     * than only suppressing future ones (#290 criterion 2). Suppressing
     * alone would leave the relay counting signals this node has stopped
     * reporting, so a paused holder would keep the headset until
     * something else outranked it — precisely the situation the user is
     * trying to escape.
     *
     * The flag is set **before** ending, so a failure part-way through
     * leaves the node paused rather than half-paused: the next
     * registration carries the shrunken `activeEvents` and the relay
     * reconciles (#178). The opposite order could leave triggers ended
     * on a node that is still emitting.
     */
    suspend fun toggle(): Boolean {
        val wantToPause = !isPaused()
        store.setPaused(wantToPause)
        if (wantToPause) {
            for (type in node.activeEventKinds()) {
                node.endEvent(type)
            }
        }
        return wantToPause
    }
}
