package com.thrw.adapter.android.config

import java.net.URI

/**
 * Where this adapter's MQTT client connects, resolved from a relay URL.
 *
 * Per ADR 0005 that URL is *build-time configuration* - it comes from
 * `packages/adapter-android/config/adapter.properties` via the generated
 * [BuildConfig], never a literal inline in source. Self-hosters point that
 * file at their own relay and rebuild; nothing here needs editing.
 *
 * ADR 0001 makes MQTT over WebSocket/TLS the transport, so `wss://` is the
 * expected scheme. The other schemes are supported because a local broker
 * (CI, or a self-hoster's LAN box) legitimately runs without TLS, and
 * because this adapter's own integration tests point at one.
 */
data class RelayConfig(
    val host: String,
    val port: Int,
    val tls: Boolean,
    val webSocket: Boolean,
    val webSocketPath: String,
) {
    companion object {
        /** ADR 0001's transport: MQTT over WebSocket/TLS. */
        const val SCHEME_WEBSOCKET_TLS = "wss"
        const val SCHEME_WEBSOCKET = "ws"
        const val SCHEME_MQTT_TLS = "mqtts"
        const val SCHEME_MQTT = "mqtt"

        /**
         * Parses a relay URL such as `wss://relay.example.com:8884/mqtt`.
         *
         * Falls back to each scheme's conventional port when the URL omits
         * one, and to `/mqtt` when a WebSocket URL has no path.
         */
        fun fromUrl(url: String): RelayConfig {
            val uri = URI(url)
            val scheme = (uri.scheme ?: "").lowercase()
            val host = uri.host ?: throw IllegalArgumentException("Relay URL has no host: $url")

            val tls = when (scheme) {
                SCHEME_WEBSOCKET_TLS, SCHEME_MQTT_TLS -> true
                SCHEME_WEBSOCKET, SCHEME_MQTT -> false
                else -> throw IllegalArgumentException("Unsupported relay URL scheme '$scheme' in $url")
            }
            val webSocket = scheme == SCHEME_WEBSOCKET_TLS || scheme == SCHEME_WEBSOCKET

            val defaultPort = when {
                webSocket && tls -> 443
                webSocket -> 80
                tls -> 8883
                else -> 1883
            }

            val path = uri.path.orEmpty().ifEmpty { "/mqtt" }

            return RelayConfig(
                host = host,
                port = if (uri.port != -1) uri.port else defaultPort,
                tls = tls,
                webSocket = webSocket,
                // HiveMQ's MqttWebSocketConfig takes the path without its
                // leading slash ("mqtt", not "/mqtt").
                webSocketPath = path.removePrefix("/"),
            )
        }

        /** The build-time-configured relay, per ADR 0005. */
        fun fromBuildConfig(): RelayConfig = fromUrl(BuildConfig.RELAY_URL)
    }
}
