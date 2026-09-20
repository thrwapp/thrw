package com.thrw.adapter.android.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * #210. The relay stamps every command with `seq` and `epoch`. This
 * adapter does not read them yet, and must keep working while it does
 * not - that is the whole basis for shipping the relay half first and
 * the adapter half separately, rather than as one flag day.
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
    }

    @Test
    fun `decodes a release the same way`() {
        val wire = """{"type":"release","seq":9,"epoch":"any"}"""

        assertEquals(
            CommandType.RELEASE,
            ProtocolJson.decodeFromString(CommandPayload.serializer(), wire).type,
        )
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
