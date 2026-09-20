package com.thrw.adapter.android.protocol

import com.thrw.adapter.android.identity.FakeSharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Acceptance criterion 3: the mark has to outlive the process, because
 * Android kills and restarts the foreground service routinely and the
 * broker may redeliver a QoS 1 command to the node that comes back.
 *
 * Against [FakeSharedPreferences] rather than a real `Context`, which is
 * stubbed to nulls in unit tests (`isReturnDefaultValues`) - the same
 * seam and the same limitation as `AdapterProvisioningTest`.
 */
class SharedPreferencesSequenceStoreTest {
    @Test
    fun `a store that has never been written reads back nothing`() {
        assertNull(SharedPreferencesSequenceStore(FakeSharedPreferences()).load(RESOURCE_AUDIO))
    }

    @Test
    fun `a saved mark round-trips`() {
        val prefs = FakeSharedPreferences()

        SharedPreferencesSequenceStore(prefs).save(RESOURCE_AUDIO, SequenceMark("e1", 42))

        assertEquals(
            SequenceMark("e1", 42),
            SharedPreferencesSequenceStore(prefs).load(RESOURCE_AUDIO),
        )
    }

    /** A second store over the same prefs is what a restart looks like. */
    @Test
    fun `the mark survives the store being rebuilt`() {
        val prefs = FakeSharedPreferences()
        SharedPreferencesSequenceStore(prefs).save(RESOURCE_AUDIO, SequenceMark("e1", 3))

        val gate = CommandSequenceGate(SharedPreferencesSequenceStore(prefs))

        assertEquals(false, gate.accepts(CommandPayload(CommandType.CLAIM, 3, "e1")))
        assertEquals(true, gate.accepts(CommandPayload(CommandType.CLAIM, 4, "e1")))
    }

    @Test
    fun `resources are stored under separate keys`() {
        val prefs = FakeSharedPreferences()
        val store = SharedPreferencesSequenceStore(prefs)

        store.save("audio", SequenceMark("e1", 10))
        store.save("hid", SequenceMark("e1", 2))

        assertEquals(SequenceMark("e1", 10), store.load("audio"))
        assertEquals(SequenceMark("e1", 2), store.load("hid"))
    }

    /**
     * `seq 0` is a legitimate stored value and must not read back as
     * "nothing stored" - which is why the sentinel is -1 rather than the
     * 0 `getLong` would otherwise default to. The relay's first command
     * in an epoch is seq 1, so this is defensive today; it stops being
     * defensive the moment anything ever stamps a zero.
     */
    @Test
    fun `a stored zero is a mark, not an absence`() {
        val prefs = FakeSharedPreferences()
        val store = SharedPreferencesSequenceStore(prefs)

        store.save(RESOURCE_AUDIO, SequenceMark("e1", 0))

        assertEquals(SequenceMark("e1", 0), store.load(RESOURCE_AUDIO))
    }
}
