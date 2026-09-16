package com.thrw.adapter.android.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The wire format is the cross-language contract: nothing in the build
 * catches a Kotlin enum whose JSON spelling has drifted from the
 * TypeScript union in `packages/protocol/src/index.ts`, so assert the
 * encoded bytes.
 */
class PayloadsTest {
    @Test
    fun `EventKind encodes to protocol's exact string union members`() {
        val encoded = EventKind.entries.map {
            ProtocolJson.encodeToString(EventKind.serializer(), it)
        }

        assertEquals(listOf("\"call\"", "\"manual_claim\"", "\"voip\"", "\"media\""), encoded)
    }

    @Test
    fun `Platform encodes to protocol's exact string union members`() {
        val encoded = Platform.entries.map {
            ProtocolJson.encodeToString(Platform.serializer(), it)
        }

        assertEquals(listOf("\"android\"", "\"mac\"", "\"ipad\"", "\"linux\""), encoded)
    }

    @Test
    fun `manifest field names match protocol's NodeManifest`() {
        val json = ProtocolJson.encodeToString(NodeManifest.serializer(), MANIFEST)

        assertEquals(
            """{"nodeId":"pixel-10-pro","platform":"android","displayName":"Pixel 10 Pro",""" +
                """"adapterVersion":"0.0.0","supportedEventKinds":["call","media"]}""",
            json,
        )
    }

    @Test
    fun `event payload matches relay-core's EventPayload shape`() {
        val json = ProtocolJson.encodeToString(EventPayload.serializer(), EventPayload(EventKind.VOIP, 3))

        assertEquals("""{"type":"voip","priority":3}""", json)
    }

    @Test
    fun `registration payload carries the kind discriminator and the manifest`() {
        val json = ProtocolJson.encodeToString(
            RegistrationPayload.serializer(),
            RegistrationPayload(manifest = MANIFEST),
        )

        assertEquals(true, json.startsWith("""{"kind":"register","manifest":{"""), json)
    }

    @Test
    fun `commands decode from relay-core's CommandPayload shape`() {
        assertEquals(
            CommandPayload(CommandType.CLAIM),
            ProtocolJson.decodeFromString(CommandPayload.serializer(), """{"type":"claim"}"""),
        )
        assertEquals(
            CommandPayload(CommandType.RELEASE),
            ProtocolJson.decodeFromString(CommandPayload.serializer(), """{"type":"release"}"""),
        )
    }

    @Test
    fun `unknown command fields are tolerated so a newer relay doesn't break older adapters`() {
        val decoded = ProtocolJson.decodeFromString(
            CommandPayload.serializer(),
            """{"type":"claim","issuedAt":"2026-09-16T00:00:00Z"}""",
        )

        assertEquals(CommandPayload(CommandType.CLAIM), decoded)
    }

    @Test
    fun `manifest strings needing JSON escaping survive a round trip`() {
        val awkward = MANIFEST.copy(displayName = """Tom's "work" Pixel \ 中文""")

        val roundTripped = ProtocolJson.decodeFromString(
            NodeManifest.serializer(),
            ProtocolJson.encodeToString(NodeManifest.serializer(), awkward),
        )

        assertEquals(awkward, roundTripped)
    }

    private companion object {
        val MANIFEST = NodeManifest(
            nodeId = "pixel-10-pro",
            platform = Platform.ANDROID,
            displayName = "Pixel 10 Pro",
            adapterVersion = "0.0.0",
            supportedEventKinds = listOf(EventKind.CALL, EventKind.MEDIA),
        )
    }
}
