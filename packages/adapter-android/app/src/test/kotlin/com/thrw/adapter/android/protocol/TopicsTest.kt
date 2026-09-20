package com.thrw.adapter.android.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins the Kotlin topic builders and QoS constants to the exact shapes in
 * docs/spec/architecture.md's "MQTT topic design" section (and therefore to
 * `packages/protocol/src/index.ts`, which they mirror). If one of these
 * assertions has to change, that's an ADR, not a code fix.
 */
class TopicsTest {
    @Test
    fun `events topic matches the frozen shape`() {
        assertEquals(
            "thrw/acct-1/nodes/pixel-10-pro/audio/events",
            Topics.events("acct-1", "pixel-10-pro", ResourceType.AUDIO),
        )
    }

    @Test
    fun `commands topic matches the frozen shape`() {
        assertEquals(
            "thrw/acct-1/commands/pixel-10-pro/audio",
            Topics.commands("acct-1", "pixel-10-pro", ResourceType.AUDIO),
        )
    }

    @Test
    fun `state topic matches the frozen shape`() {
        assertEquals("thrw/acct-1/state/audio", Topics.state("acct-1", ResourceType.AUDIO))
    }

    @Test
    fun `heartbeat topic matches the frozen shape`() {
        assertEquals("thrw/acct-1/nodes/pixel-10-pro/heartbeat", Topics.heartbeat("acct-1", "pixel-10-pro"))
    }

    @Test
    fun `every topic is account-scoped for broker-level multi-tenant isolation`() {
        val topics = listOf(
            Topics.events("acct-1", "n", ResourceType.AUDIO),
            Topics.commands("acct-1", "n", ResourceType.AUDIO),
            Topics.state("acct-1", ResourceType.AUDIO),
            Topics.heartbeat("acct-1", "n"),
        )

        topics.forEach { assertEquals(true, it.startsWith("thrw/acct-1/"), "not account-scoped: $it") }
    }

    @Test
    fun `qos values mirror protocol's TopicQos`() {
        assertEquals(1, TopicQos.EVENTS_QOS)
        assertEquals(1, TopicQos.COMMANDS_QOS)
        assertEquals(true, TopicQos.STATE_RETAINED)
        assertEquals(0, TopicQos.HEARTBEAT_QOS)
    }
}
