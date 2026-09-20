package com.thrw.adapter.android.protocol

import android.content.Context
import android.content.SharedPreferences

/**
 * [SequenceStore] backed by SharedPreferences, so the high-water mark
 * survives the adapter process dying and being restarted by Android -
 * which it does routinely (#161 made that survivable, and the foreground
 * service is restarted on boot by `BootCompletedReceiver`).
 *
 * That durability is acceptance criterion 3: the broker may redeliver a
 * QoS 1 command to the reconnecting node, and an in-memory mark would
 * have forgotten that the command was already acted on.
 *
 * The pair is written as one `apply()` rather than two, unlike
 * [com.thrw.adapter.android.identity.AdapterProvisioning]: a mark whose
 * epoch and sequence come from different commands is not a partial
 * write, it is a *wrong* one, and it would be read on every command
 * rather than once at startup.
 */
class SharedPreferencesSequenceStore(private val prefs: SharedPreferences) : SequenceStore {
    constructor(context: Context) : this(
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
    )

    override fun load(resource: String): SequenceMark? {
        val epoch = prefs.getString(epochKey(resource), null) ?: return null
        // -1 rather than 0: the relay's first command in an epoch is
        // seq 1, so 0 is a legitimate-looking "nothing seen yet" value
        // and must not be confused with a stored mark.
        val seq = prefs.getLong(seqKey(resource), -1L)
        if (seq < 0) return null
        return SequenceMark(epoch = epoch, seq = seq)
    }

    override fun save(resource: String, mark: SequenceMark) {
        prefs.edit()
            .putString(epochKey(resource), mark.epoch)
            .putLong(seqKey(resource), mark.seq)
            .apply()
    }

    private fun epochKey(resource: String) = "epoch_$resource"

    private fun seqKey(resource: String) = "seq_$resource"

    private companion object {
        const val PREFS_NAME = "thrw_command_sequence"
    }
}
