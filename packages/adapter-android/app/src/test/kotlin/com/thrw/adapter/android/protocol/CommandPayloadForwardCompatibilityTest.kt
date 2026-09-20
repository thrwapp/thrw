package com.thrw.adapter.android.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * #210. The relay stamps every command with `seq` and `epoch`.
 *
 * These tests were written for the relay half, when this adapter did
 * **not** read the fields and had to keep working anyway - the whole
 * basis for shipping the two halves separately rather than as one flag
 * day. The adapter half now reads them, so the assertions below also
 * pin that the values decode rather than merely that the message
 * survives.
 *
 * `ProtocolJson` already sets `ignoreUnknownKeys = true` and its comment
 * anticipates exactly this. These tests turn that comment into something
 * that fails if it stops being true.
 *
 * Asserted against the **exact bytes** a real relay emits, captured from
 * the wire on 2026-09-20 rather than hand-written from the type.
 */
class CommandPayloadForwardCompatibilityTest {
    @Test
    fun `decodes a command carrying sequencing fields it does not know about`() {
        val wire = """{"type":"claim","seq":1,"epoch":"2174ac4b-0ab7-4cff-967e-8a352e3bd7c8"}"""

        val decoded = ProtocolJson.decodeFromString(CommandPayload.serializer(), wire)

        assertEquals(CommandType.CLAIM, decoded.type)
        assertEquals(1L, decoded.seq)
        assertEquals("2174ac4b-0ab7-4cff-967e-8a352e3bd7c8", decoded.epoch)
    }

    @Test
    fun `decodes a release the same way`() {
        val wire = """{"type":"release","seq":9,"epoch":"any"}"""

        val decoded = ProtocolJson.decodeFromString(CommandPayload.serializer(), wire)

        assertEquals(CommandType.RELEASE, decoded.type)
        assertEquals(9L, decoded.seq)
    }

    /**
     * The pre-#210 wire shape, which a relay older than this adapter
     * still emits. Both fields must decode as absent rather than
     * failing - [CommandSequenceGate] treats that as acceptable.
     */
    @Test
    fun `a command with no sequencing fields decodes with both absent`() {
        val decoded = ProtocolJson.decodeFromString(CommandPayload.serializer(), """{"type":"claim"}""")

        assertEquals(CommandType.CLAIM, decoded.type)
        assertNull(decoded.seq)
        assertNull(decoded.epoch)
    }

    /**
     * The guarantee is *unknown fields are ignored*, not *these two
     * specific fields*. A relay that grows a third must not break this
     * adapter either.
     */
    @Test
    fun `an unrecognised field is ignored`() {
        val wire = """{"type":"claim","seq":1,"epoch":"e","somethingAddedLater":{"a":[1,2]}}"""

        assertEquals(
            CommandType.CLAIM,
            ProtocolJson.decodeFromString(CommandPayload.serializer(), wire).type,
        )
    }
}
