package com.thrw.adapter.android.protocol

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * Asserts this adapter's topic builder against the **shared** fixture at
 * `packages/protocol/fixtures/topics.json` (#171).
 *
 * There are three hand-written implementations of the topic contract -
 * TypeScript in `packages/protocol`, Swift in `adapter-mac`, and this
 * one. Each had its own tests and nothing asserted they agreed, so they
 * could drift apart silently and the only symptom would be a node going
 * quiet on real hardware. That is precisely the failure mode behind
 * #174, #175 and #182, and the risk peaks during the ADR 0015 migration
 * because all three move at once.
 */
class TopicsFixtureTest {
    private val fixture: JsonObject by lazy {
        // Walked up from the module directory rather than copied into
        // test resources: a copy is a second source of truth, which is
        // the thing this test exists to prevent.
        val file = File(System.getProperty("user.dir"))
            .resolve("../../protocol/fixtures/topics.json")
            .normalize()
        check(file.exists()) { "shared topic fixture not found at $file" }
        Json.parseToJsonElement(file.readText()) as JsonObject
    }

    private fun str(vararg path: String): String {
        var node: JsonObject = fixture
        for (key in path.dropLast(1)) node = node[key] as JsonObject
        return node.getValue(path.last()).jsonPrimitive.content
    }

    private val account get() = str("account")
    private val node get() = str("node")

    @Test
    fun `events topic matches the shared fixture`() {
        assertEquals(str("topics", "events"), Topics.events(account, node, ResourceType.AUDIO))
    }

    @Test
    fun `commands topic matches the shared fixture`() {
        assertEquals(str("topics", "commands"), Topics.commands(account, node, ResourceType.AUDIO))
    }

    @Test
    fun `state topic matches the shared fixture`() {
        assertEquals(str("topics", "state"), Topics.state(account, ResourceType.AUDIO))
    }

    /**
     * No resource segment - ADR 0015 lists exactly three topics that gain
     * one, and liveness is per-node.
     */
    @Test
    fun `heartbeat topic has no resource segment`() {
        val topic = Topics.heartbeat(account, node)
        assertEquals(str("topics", "heartbeat"), topic)
        assertFalse(topic.contains(ResourceType.AUDIO.wire))
    }

    @Test
    fun `hid topics match the shared fixture`() {
        assertEquals(str("hid", "events"), Topics.events(account, node, ResourceType.HID))
        assertEquals(str("hid", "commands"), Topics.commands(account, node, ResourceType.HID))
        assertEquals(str("hid", "state"), Topics.state(account, ResourceType.HID))
    }
}
