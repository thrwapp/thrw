package com.thrw.adapter.android.protocol

/**
 * The high-water mark this node has already acted on, for one resource
 * type.
 *
 * The epoch is part of the mark rather than stored beside it because the
 * two are only meaningful together: a sequence number from a different
 * relay process says nothing about ordering, so comparing one against
 * the other is never valid. Pairing them makes that impossible to get
 * wrong by accident.
 */
data class SequenceMark(val epoch: String, val seq: Long)

/**
 * Where a [CommandSequenceGate] keeps its mark across process restarts.
 *
 * An interface rather than SharedPreferences directly so the gate's
 * logic is testable without Android, the same seam
 * [com.thrw.adapter.android.identity.AdapterProvisioning] uses.
 */
interface SequenceStore {
    fun load(resource: String): SequenceMark?

    fun save(resource: String, mark: SequenceMark)
}

/** For tests, and for a node built without persistence. */
class InMemorySequenceStore : SequenceStore {
    private val marks = mutableMapOf<String, SequenceMark>()

    override fun load(resource: String): SequenceMark? = synchronized(marks) { marks[resource] }

    override fun save(resource: String, mark: SequenceMark) {
        synchronized(marks) { marks[resource] = mark }
    }
}

/**
 * ADR 0018 decision 1 (#210), adapter half: decides whether a command
 * the relay just delivered is the newest one this node has seen, and
 * remembers the ones it acted on.
 *
 * The relay stamps every command with a `seq` (monotonic per account /
 * node / resource type) and an `epoch` (one per relay process). Commands
 * ride MQTT at QoS 1, which is at-*least*-once: the broker is entitled to
 * redeliver, and does so on reconnect. Without this gate a redelivered
 * `claim` that arrives after a newer `release` re-claims the headset -
 * exactly the failure ADR 0018 names.
 *
 * ## Two rules, and why the second one exists
 *
 * 1. Within one epoch, a command is acted on only if its `seq` is
 *    **strictly greater** than the last one acted on. Equal means a
 *    duplicate delivery of something already done.
 * 2. A **different epoch resets the mark entirely**. The relay holds its
 *    counters in memory (the premise of #178), so a relay restart takes
 *    them back to zero while this node still holds a persisted mark.
 *    Without rule 2 every subsequent command is discarded as stale,
 *    permanently, until adapter state is cleared by hand - the
 *    "restart every adapter manually" failure #178 exists to remove,
 *    reintroduced by the mechanism meant to harden things. The relay
 *    restarts routinely.
 *
 * ## An unsequenced command is accepted
 *
 * [accepts] returns true when either field is absent, and [record] then
 * stores nothing. A command with no `seq` can only come from a relay
 * older than ADR 0018, and a node that discarded those would be
 * completely deaf rather than merely unprotected. Refusing to act is the
 * more dangerous failure here: the mark exists to prevent a *wrong*
 * switch, not to prevent switching.
 *
 * ## #173's re-asserted claim is not discarded
 *
 * #173 has the relay re-publish a `claim` to a node that registers while
 * the relay still considers it the holder - which is what un-sticks a
 * device that restarted while holding. That claim must survive this
 * gate, or #173 regresses silently and invisibly.
 *
 * It does, in both directions, and by construction rather than luck:
 *
 * - *This node* restarted. The relay is the same process, so its counter
 *   has kept climbing while the node was away; the re-asserted claim
 *   carries a higher `seq` than the mark, and rule 1 accepts it.
 * - *The relay* restarted. It is a new process with a new epoch, so rule
 *   2 clears the mark before rule 1 is ever consulted.
 *
 * Both are covered by tests in `CommandSequenceGateTest`.
 *
 * Mirrored by `adapter-mac`'s `CommandSequenceGate.swift` - change both
 * together.
 */
class CommandSequenceGate(
    private val store: SequenceStore = InMemorySequenceStore(),
    private val resource: String = RESOURCE_AUDIO,
) {
    /**
     * Whether [command] should be acted on. A pure query: it reads the
     * mark and does not move it, so asking twice gives the same answer
     * and a command that fails to execute is not silently marked done.
     */
    fun accepts(command: CommandPayload): Boolean {
        val seq = command.seq ?: return true
        val epoch = command.epoch ?: return true
        val mark = store.load(resource) ?: return true
        if (mark.epoch != epoch) return true
        return seq > mark.seq
    }

    /**
     * Moves the mark to [command], if it is ahead of where the mark
     * already is.
     *
     * Called **after** the command has been executed successfully, not
     * before. A claim that throws (headset off, out of range, busy) has
     * not happened, and leaving the mark behind lets the broker's
     * redelivery retry it. The cost is that a crash between executing
     * and recording allows one repeat - and a repeated claim or release
     * is idempotent at the Bluetooth layer, whereas a *lost* one leaves
     * the user with no audio.
     */
    fun record(command: CommandPayload) {
        val seq = command.seq ?: return
        val epoch = command.epoch ?: return
        val mark = store.load(resource)
        if (mark != null && mark.epoch == epoch && mark.seq >= seq) return
        store.save(resource, SequenceMark(epoch = epoch, seq = seq))
    }
}
