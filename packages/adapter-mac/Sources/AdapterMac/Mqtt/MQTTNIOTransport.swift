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
/// 3. **Pure Swift/SwiftNIO, so it's not tied to Apple platforms.**
///    Unlike `IOBluetoothPeripheralGateway` (`#if canImport(IOBluetooth)`,
///    macOS-only by necessity), nothing about talking MQTT is inherently
///    Apple-platform-specific. CocoaMQTT's dependency tree leans on
///    Apple-platform assumptions in places; MQTTNIO is built for
///    swift-server and is exercised on Linux upstream.
///
///    **Correction (#128):** this reason was originally written as
///    "Linux-portable, and the repo's agent-code/agent-eval automation
///    runs `swift test` on a Linux container." That premise is false -
///    agent-code.yml installs no Swift toolchain and cannot invoke
///    `swift` at all, and per ADR 0004 Linux is the *Rust* adapter's
///    platform. Nothing in this repo builds this package on Linux.
///    Reasons 1 and 2 are the load-bearing ones; keep this third only as
///    the mild tiebreaker it actually is.
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

    /// Guards everything below. `NSLock` rather than an actor for the
    /// same reason ``SelfCooldown`` uses one: this is touched from
    /// MQTTNIO's own callback threads as well as from Swift tasks.
    private let lock = NSLock()
    /// Live subscriptions, re-issued after a reconnect.
    private var subscriptions: [String: Int] = [:]
    /// Set by the node, to re-register after a reconnect.
    private var reconnectedHandler: (@Sendable () -> Void)?
    /// Stops the close listener fighting an intentional shutdown.
    private var isShuttingDown = false
    /// Stops two overlapping reconnect loops after a flapping link.
    private var isReconnecting = false

    private init(client: MQTTClient) {
        self.client = client
        client.addCloseListener(named: Self.closeListenerName) { [weak self] _ in
            self?.connectionClosed()
        }
    }

    private static let closeListenerName = "AdapterMac.reconnect"

    /// Synchronous on purpose: taking an `NSLock` directly inside an
    /// `async` function is unavailable under the Swift 6 language mode
    /// (there is no suspension point inside, so there is nothing to be
    /// unsafe about - but the compiler cannot know that). Every locked
    /// read/write below goes through here.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func onReconnected(_ handler: @escaping @Sendable () -> Void) {
        withLock { reconnectedHandler = handler }
    }

    /// MQTTNIO has no automatic reconnect, so this is it (#182).
    ///
    /// Without it an adapter that loses its connection never comes back:
    /// it keeps running, its menu bar item stays up, and it is silently
    /// useless until relaunched. Observed for real when a relay deploy
    /// restarted the broker and neither adapter returned. The triggers
    /// are mundane - a network change, a sleep/wake, any relay deploy.
    private func connectionClosed() {
        let shouldReconnect = withLock {
            let go = !isShuttingDown && !isReconnecting
            if go { isReconnecting = true }
            return go
        }
        guard shouldReconnect else { return }
        Task { await reconnectLoop() }
    }

    private func reconnectLoop() async {
        var delay = Self.initialReconnectDelay
        while true {
            if withLock({ isShuttingDown }) { break }

            // Jitter so several nodes coming back from a shared outage -
            // a relay deploy, a router reboot - don't all reconnect and
            // re-register on the same tick (ADR 0020's reconnect jitter).
            let jitter = Duration.milliseconds(Int.random(in: 0...2000))
            try? await Task.sleep(for: delay + jitter)

            do {
                _ = try await client.connect()
                await restoreSubscriptions()
                let handler = withLock { () -> (@Sendable () -> Void)? in
                    isReconnecting = false
                    return reconnectedHandler
                }
                handler?()
                return
            } catch {
                delay = min(delay * 2, Self.maxReconnectDelay)
            }
        }
        withLock { isReconnecting = false }
    }

    /// Re-issues every live subscription.
    ///
    /// The session is clean, so reconnecting restores the *connection*,
    /// not the subscriptions - without this the client comes back
    /// connected and **deaf**, never receiving another claim or release
    /// while looking perfectly healthy. (The publish listeners are
    /// client-level and do survive, so only the SUBSCRIBE needs
    /// re-sending.)
    private func restoreSubscriptions() async {
        let live = withLock { subscriptions }
        for (topic, qos) in live {
            _ = try? await client.subscribe(to: [MQTTSubscribeInfo(topicFilter: topic, qos: mqttQos(qos))])
        }
    }

    private static let initialReconnectDelay: Duration = .seconds(1)
    private static let maxReconnectDelay: Duration = .seconds(30)

    /// Connects to `config`'s relay as `clientId` and returns a
    /// connected transport.
    ///
    /// `clientId` is the node id: the broker's account-scoped ACLs
    /// (architecture.md, "MQTT topic design") key off the connecting
    /// client, so it must not be randomly generated per process - same
    /// requirement `adapter-android`'s `HiveMqttTransport.connect` notes.
    /// `credentials` is optional because an anonymous broker is a real,
    /// supported configuration (a local or self-hosted broker with
    /// `allow_anonymous = true` - which is how this package's tests
    /// connect). Passing `nil` connects anonymously; the deployed relay
    /// runs `allow_anonymous = false` and rejects that with
    /// `badUserNameOrPassword` (#147).
    public static func connect(
        config: RelayConfig,
        clientId: String,
        credentials: RelayCredentials? = nil
    ) async throws -> MQTTNIOTransport {
        let configuration = MQTTClient.Configuration(
            version: .v3_1_1,
            userName: credentials?.username,
            password: credentials?.password,
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

            withLock { subscriptions[topic] = qos }
            continuation.onTermination = { [client, weak self] _ in
                client.removePublishListener(named: listenerName)
                guard let self else { return }
                self.withLock { _ = self.subscriptions.removeValue(forKey: topic) }
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
        // Before shutdown, so the close listener treats the resulting
        // disconnect as intentional rather than starting a reconnect loop
        // against a client that is going away.
        withLock { isShuttingDown = true }
        client.removeCloseListener(named: Self.closeListenerName)
        try await client.shutdown()
    }

    private func mqttQos(_ qos: Int) -> MQTTQoS {
        guard let value = MQTTQoS(rawValue: UInt8(qos)) else {
            preconditionFailure("Not a valid MQTT QoS level: \(qos)")
        }
        return value
    }
}
