import Foundation
import MQTTNIO
import NIOCore
import NIOPosix

/// ``MqttTransport`` backed by MQTTNIO (ADR 0001).
///
/// ## Dependency choice: MQTTNIO over CocoaMQTT
///
/// The issue named both as reasonable options. MQTTNIO wins here for
/// three reasons:
///
/// 1. **Native async/await.** MQTTNIO's `AsyncAwaitSupport` extensions
///    give `connect`/`publish`/`subscribe`/`shutdown` as real `async
///    throws` functions, matching this package's existing actor-based
///    style (`BluetoothConnectionManager`, `IOBluetoothPeripheralGateway`)
///    and AGENTS.md's "use Swift 6 concurrency features where
///    applicable" - no `CheckedContinuation` bridging needed here, unlike
///    both Bluetooth gateways.
/// 2. **WebSocket + TLS out of the box.** `MQTTClient.Configuration`
///    takes `useWebSockets`/`useSSL`/`webSocketURLPath` directly - ADR
///    0001's transport - with no extra glue.
/// 3. **Pure Swift/SwiftNIO, so it's Linux-portable.** Unlike
///    `IOBluetoothPeripheralGateway` (`#if canImport(IOBluetooth)`,
///    macOS-only by necessity), nothing about talking MQTT is inherently
///    Apple-platform-specific, and this repo's `agent-code`/`agent-eval`
///    automation runs `swift test` on a Linux container (only
///    `ci.yml`'s dedicated `mac-ipad` job uses a real macOS runner - see
///    docs/handoffs/101.md). CocoaMQTT's dependency tree leans on
///    Apple-platform assumptions in places; MQTTNIO is built for
///    swift-server and is exercised on Linux upstream.
///
/// The trade-off, named rather than hidden: MQTTNIO pulls in the
/// SwiftNIO stack (`swift-nio`, `swift-nio-ssl`, `swift-nio-transport-services`,
/// `swift-log`, `swift-atomics`) - a heavier dependency tree than
/// CocoaMQTT's. Justified by points 1-3 above, especially point 3, which
/// CocoaMQTT cannot offer at all.
///
/// MQTT 3.1.1 rather than 5, to match the rest of the system: the relay
/// side (`packages/relay-core/src/mqtt-client.ts`) uses the `mqtt` npm
/// package, whose default `protocolVersion` is 4 (= 3.1.1). ADR 0001
/// specifies the transport, QoS and retained semantics, none of which
/// need MQTT 5.
public final class MQTTNIOTransport: MqttTransport, @unchecked Sendable {
    private let client: MQTTClient

    private init(client: MQTTClient) {
        self.client = client
    }

    /// Connects to `config`'s relay as `clientId` and returns a
    /// connected transport.
    ///
    /// `clientId` is the node id: the broker's account-scoped ACLs
    /// (architecture.md, "MQTT topic design") key off the connecting
    /// client, so it must not be randomly generated per process - same
    /// requirement `adapter-android`'s `HiveMqttTransport.connect` notes.
    public static func connect(config: RelayConfig, clientId: String) async throws -> MQTTNIOTransport {
        let configuration = MQTTClient.Configuration(
            version: .v3_1_1,
            useSSL: config.tls,
            useWebSockets: config.webSocket,
            // MQTTNIO's WebSocketConfiguration ignores this entirely when
            // useWebSockets is false, but only construct it from a path
            // that's meaningful in that case.
            webSocketURLPath: config.webSocket ? config.webSocketPath : nil
        )

        let client = MQTTClient(
            host: config.host,
            port: config.port,
            identifier: clientId,
            // The shared, process-wide singleton rather than a
            // dedicated group per client (`.createNew` is deprecated in
            // this version of swift-nio): one MQTTNIOTransport is not
            // expected to be the only thing in a host process using
            // SwiftNIO, and the singleton is exactly what avoids each
            // one spinning up its own thread pool.
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: configuration
        )
        _ = try await client.connect()
        return MQTTNIOTransport(client: client)
    }

    public func publish(topic: String, payload: String, qos: Int, retained: Bool) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: payload.utf8.count)
        buffer.writeString(payload)
        try await client.publish(to: topic, payload: buffer, qos: mqttQos(qos), retain: retained)
    }

    public func subscribe(topic: String, qos: Int) -> AsyncStream<String> {
        AsyncStream { continuation in
            let listenerName = "AdapterMac.subscribe.\(topic).\(UUID().uuidString)"

            client.addPublishListener(named: listenerName) { result in
                guard case .success(let publishInfo) = result, publishInfo.topicName == topic else { return }
                continuation.yield(String(buffer: publishInfo.payload))
            }

            continuation.onTermination = { [client] _ in
                client.removePublishListener(named: listenerName)
            }

            Task { [client] in
                do {
                    _ = try await client.subscribe(to: [MQTTSubscribeInfo(topicFilter: topic, qos: mqttQos(qos))])
                } catch {
                    // Matches the Kotlin HiveMqttTransport's own
                    // behavior: a failed SUBSCRIBE ends the stream rather
                    // than silently leaving a listener registered for a
                    // subscription that was never actually granted.
                    continuation.finish()
                }
            }
        }
    }

    public func close() async throws {
        try await client.shutdown()
    }

    private func mqttQos(_ qos: Int) -> MQTTQoS {
        guard let value = MQTTQoS(rawValue: UInt8(qos)) else {
            preconditionFailure("Not a valid MQTT QoS level: \(qos)")
        }
        return value
    }
}
