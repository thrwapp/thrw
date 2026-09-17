import Foundation

/// The Mac adapter as a node on the relay: `packages/protocol`'s node
/// interface, over this device's own MQTT connection to the relay's
/// broker (architecture.md, "System components"). Swift mirror of
/// `adapter-android`'s `AndroidNode.kt` (`:53-87` for
/// register/emitEvent/onClaim/onRelease, `:98-110` for
/// `listenForCommands`).
///
/// Out of scope on purpose (same as `AndroidNode`):
/// - **The connection state machine** (idle / pre-claim / claim /
///   active). Frozen contract per ADR 0010 / 0011 / 0013 - a separate
///   ADR plus human review, not a routine agent PR. `onClaim`/`onRelease`
///   here are the plain side-effecting hooks the protocol declares;
///   nothing in this class tracks or transitions a node state.
/// - **Trigger detection** (call/VoIP/media monitors). Nothing calls
///   `emitEvent` yet except a caller wiring this node up directly - the
///   Mac equivalent of `adapter-android`'s `triggers/` package (and the
///   `endEvent`/`EventLifecycle` addition that came with it, #68) is a
///   separate follow-up issue, mirroring how adapter-android itself
///   split that out from #67.
/// - **Priority rules.** Server-side in the relay, "never duplicated in
///   adapters" (architecture.md). This node reports; it does not decide.
public final class MacNode: NodeInterface {
    private let accountId: String
    private let nodeId: String
    private let headsetIdentifier: UUID
    private let transport: MqttTransport
    private let bluetooth: BluetoothConnectionManager

    public init(
        accountId: String,
        nodeId: String,
        headsetIdentifier: UUID,
        transport: MqttTransport,
        bluetooth: BluetoothConnectionManager
    ) {
        self.accountId = accountId
        self.nodeId = nodeId
        self.headsetIdentifier = headsetIdentifier
        self.transport = transport
        self.bluetooth = bluetooth
    }

    /// Publishes this node's manifest so the relay's device registry
    /// knows what the node can do. Rides the node's events topic (the
    /// only node-publishes topic in the frozen topic set) inside a
    /// `RegistrationPayload` envelope - see docs/handoffs/67.md.
    public func register(manifest: NodeManifest) async throws {
        try await publishToEvents(RegistrationPayload(manifest: manifest))
    }

    /// Publishes a trigger to the events topic at QoS 1 per `TopicQos`.
    public func emitEvent(type: EventKind, priority: Priority) async throws {
        try await publishToEvents(EventPayload(type: type, priority: priority))
    }

    /// Claim won: connect the headset to this device.
    public func onClaim() async throws {
        try await bluetooth.connect(deviceIdentifier: headsetIdentifier)
    }

    /// Claim lost (or released): disconnect the headset from this device.
    public func onRelease() async throws {
        try await bluetooth.disconnect(deviceIdentifier: headsetIdentifier)
    }

    /// Subscribes to this node's commands topic and dispatches each
    /// relay-issued command to ``onClaim``/``onRelease``. Suspends until
    /// the underlying stream ends (the transport closes, or its
    /// subscription itself fails - see `MQTTNIOTransport.subscribe`).
    ///
    /// Unparseable payloads are skipped rather than thrown: a malformed
    /// message from a newer relay must not tear down the subscription
    /// and leave this node deaf to the *next*, valid, claim.
    public func listenForCommands() async throws {
        let commands = transport.subscribe(
            topic: Topics.commands(account: accountId, node: nodeId),
            qos: TopicQos.commandsQos
        )
        for await payload in commands {
            guard let command = try? JSONDecoder().decode(CommandPayload.self, from: Data(payload.utf8)) else {
                continue
            }
            switch command.type {
            case .claim: try await onClaim()
            case .release: try await onRelease()
            }
        }
    }

    private func publishToEvents(_ payload: some Encodable) async throws {
        let data = try JSONEncoder().encode(payload)
        try await transport.publish(
            topic: Topics.events(account: accountId, node: nodeId),
            payload: String(decoding: data, as: UTF8.self),
            qos: TopicQos.eventsQos,
            retained: false
        )
    }
}
