import Foundation

/// Where this adapter's MQTT client connects, resolved from a relay URL.
/// Swift mirror of `adapter-android/config/RelayConfig.kt`.
///
/// Per ADR 0005 that URL is *build-time configuration* - it comes from
/// `packages/adapter-mac/config/adapter.properties` via the generated
/// `AdapterBuildConfig` (see `Plugins/GenerateAdapterConfigPlugin/`),
/// never a literal inline in source. Self-hosters point that file at
/// their own relay and rebuild; nothing here needs editing.
///
/// ADR 0001 makes MQTT over WebSocket/TLS the transport, so `wss://` is
/// the expected scheme. The other schemes are supported because a local
/// broker (CI, or a self-hoster's LAN box) legitimately runs without
/// TLS, and because this adapter's own tests point at one.
public struct RelayConfig: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let tls: Bool
    public let webSocket: Bool

    /// Always has a leading `/` (defaulting to `/mqtt`) - this is the
    /// literal HTTP request path MQTTNIO's `WebSocketConfiguration.urlPath`
    /// sends on the upgrade request. Deliberately the opposite convention
    /// from `adapter-android`'s `RelayConfig.webSocketPath`, which strips
    /// the leading slash for HiveMQ's `MqttWebSocketConfig.serverPath` -
    /// each MQTT client library gets to define its own expected shape,
    /// and this type follows MQTTNIO's rather than forcing HiveMQ's
    /// convention onto a library that doesn't use it.
    public let webSocketPath: String

    public init(host: String, port: Int, tls: Bool, webSocket: Bool, webSocketPath: String) {
        self.host = host
        self.port = port
        self.tls = tls
        self.webSocket = webSocket
        self.webSocketPath = webSocketPath
    }

    public enum ParseError: Error, Equatable {
        /// The URL couldn't be parsed at all, or had no host.
        case missingHost(url: String)
        /// A scheme other than `wss`/`ws`/`mqtts`/`mqtt`.
        case unsupportedScheme(scheme: String, url: String)
    }

    /// Parses a relay URL such as `wss://relay.example.com:8884/mqtt`.
    ///
    /// Falls back to each scheme's conventional port when the URL omits
    /// one, and to `/mqtt` when a WebSocket URL has no path.
    public static func from(url: String) throws -> RelayConfig {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            throw ParseError.missingHost(url: url)
        }

        let scheme = (components.scheme ?? "").lowercased()
        let tls: Bool
        switch scheme {
        case "wss", "mqtts":
            tls = true
        case "ws", "mqtt":
            tls = false
        default:
            throw ParseError.unsupportedScheme(scheme: scheme, url: url)
        }
        let webSocket = scheme == "wss" || scheme == "ws"

        let defaultPort: Int
        switch (webSocket, tls) {
        case (true, true): defaultPort = 443
        case (true, false): defaultPort = 80
        case (false, true): defaultPort = 8883
        case (false, false): defaultPort = 1883
        }

        return RelayConfig(
            host: host,
            port: components.port ?? defaultPort,
            tls: tls,
            webSocket: webSocket,
            webSocketPath: components.path.isEmpty ? "/mqtt" : components.path
        )
    }

    /// The build-time-configured relay, per ADR 0005.
    public static func fromBuildConfig() throws -> RelayConfig {
        try from(url: AdapterBuildConfig.relayURL)
    }
}
