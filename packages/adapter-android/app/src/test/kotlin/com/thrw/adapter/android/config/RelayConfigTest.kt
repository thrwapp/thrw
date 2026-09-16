package com.thrw.adapter.android.config

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RelayConfigTest {
    @Test
    fun `wss URL resolves to WebSocket plus TLS per ADR 0001`() {
        val config = RelayConfig.fromUrl("wss://relay.example.com:8884/mqtt")

        assertEquals("relay.example.com", config.host)
        assertEquals(8884, config.port)
        assertTrue(config.tls)
        assertTrue(config.webSocket)
        assertEquals("mqtt", config.webSocketPath)
    }

    @Test
    fun `wss URL without an explicit port defaults to 443`() {
        assertEquals(443, RelayConfig.fromUrl("wss://relay.example.com/mqtt").port)
    }

    @Test
    fun `ws URL is WebSocket without TLS, for a local or self-hosted broker`() {
        val config = RelayConfig.fromUrl("ws://localhost:8080/mqtt")

        assertFalse(config.tls)
        assertTrue(config.webSocket)
        assertEquals(80, RelayConfig.fromUrl("ws://localhost/mqtt").port)
    }

    @Test
    fun `plain mqtt schemes resolve to their conventional ports`() {
        assertEquals(1883, RelayConfig.fromUrl("mqtt://localhost").port)
        assertEquals(8883, RelayConfig.fromUrl("mqtts://relay.example.com").port)
        assertFalse(RelayConfig.fromUrl("mqtt://localhost").webSocket)
    }

    @Test
    fun `a WebSocket URL with no path falls back to the conventional mqtt path`() {
        assertEquals("mqtt", RelayConfig.fromUrl("wss://relay.example.com:8884").webSocketPath)
    }

    @Test
    fun `an unsupported scheme is rejected rather than silently downgraded`() {
        assertFailsWith<IllegalArgumentException> { RelayConfig.fromUrl("https://relay.example.com") }
    }

    @Test
    fun `a URL with no host is rejected`() {
        assertFailsWith<IllegalArgumentException> { RelayConfig.fromUrl("wss:///mqtt") }
    }

    /**
     * ADR 0005: the relay endpoint must come from build-time configuration
     * (packages/adapter-android/config/adapter.properties -> the generated
     * BuildConfig), never a literal in source. This asserts the generated
     * value is actually wired through and is ADR 0001's wss:// transport.
     */
    @Test
    fun `the build-time configured relay is reachable through RelayConfig`() {
        assertTrue(BuildConfig.RELAY_URL.startsWith("wss://"), BuildConfig.RELAY_URL)
        assertTrue(BuildConfig.LICENSING_URL.isNotBlank())

        val config = RelayConfig.fromBuildConfig()

        assertTrue(config.tls)
        assertTrue(config.webSocket)
    }
}
