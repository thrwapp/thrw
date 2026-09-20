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
/// - **Priority rules.** Server-side in the relay, "never duplicated in
///   adapters" (architecture.md). This node reports; it does not decide.
///
/// Conforms to ``EventLifecycle`` (#127) so ``VoipTriggerMonitor`` can
/// report trigger start/end through it - `emitEvent`'s signature already
/// satisfies both `NodeInterface` and `EventLifecycle` at once, so only
/// `endEvent` needed adding.
public final class MacNode: NodeInterface, EventLifecycle, HeartbeatSink {
    private let accountId: String
    private let nodeId: String
    private let headsetIdentifier: UUID
    private let transport: MqttTransport
    private let bluetooth: BluetoothConnectionManager
    /// ADR 0010 point 1 (#167) - armed by ``onClaim()``/``onRelease()``.
    private let selfCooldown: SelfCooldown

    /// Runs `handler` whenever the transport re-establishes a dropped
    /// connection (#182) - see ``MqttTransport/onReconnected(_:)``.
    public func onReconnected(_ handler: @escaping @Sendable () -> Void) {
        transport.onReconnected(handler)
    }

    /// What this node has reported as active and not yet ended (#178),
    /// sent with every registration so the relay can reconcile rather
    /// than infer.
    ///
    /// Only triggers this node actually *published* are tracked: one the
    /// self-cooldown suppressed was never told to the relay, so including
    /// it here would leak it out on the next periodic registration and
    /// undo the suppression (#167).
    private let activeEvents = ActiveEventSet()

    public init(
        accountId: String,
        nodeId: String,
        headsetIdentifier: UUID,
        transport: MqttTransport,
        bluetooth: BluetoothConnectionManager,
        selfCooldown: SelfCooldown = SelfCooldown()
    ) {
        self.accountId = accountId
        self.nodeId = nodeId
        self.headsetIdentifier = headsetIdentifier
        self.transport = transport
        self.bluetooth = bluetooth
        self.selfCooldown = selfCooldown
    }

    /// Publishes this node's manifest so the relay's device registry
    /// knows what the node can do. Rides the node's events topic (the
    /// only node-publishes topic in the frozen topic set) inside a
    /// `RegistrationPayload` envelope - see docs/handoffs/67.md.
    public func register(manifest: NodeManifest) async throws {
        try await publishToEvents(
            RegistrationPayload(manifest: manifest, activeEvents: activeEvents.snapshot())
        )
    }

    /// Publishes a trigger to the events topic at QoS 1 per `TopicQos`.
    public func emitEvent(type: EventKind, priority: Priority) async throws {
        if selfCooldown.isActive() { return }
        try await publishToEvents(EventPayload(type: type, priority: priority))
        activeEvents.insert(type)
    }

    /// The symmetric partner of ``emitEvent(type:priority:)``: the `type`
    /// trigger this node reported has stopped. Publishes an
    /// `EventEndPayload` on the same events topic at the same QoS -
    /// mirrors `AndroidNode.kt`'s own `endEvent` (#68).
    public func endEvent(type: EventKind) async throws {
        if selfCooldown.isActive() { return }
        try await publishToEvents(EventEndPayload(type: type))
        activeEvents.remove(type)
    }

    /// Claim won: connect the headset to this device.
    public func onClaim() async throws {
        defer { selfCooldown.arm() }
        try await bluetooth.connect(deviceIdentifier: headsetIdentifier)
    }

    /// Claim lost (or released): disconnect the headset from this device.
    public func onRelease() async throws {
        defer { selfCooldown.arm() }
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

    /// ``HeartbeatSink`` conformance (#142) - liveness only, so the
    /// relay's `sweepHeartbeats` doesn't reap this node.
    ///
    /// Empty payload, deliberately: architecture.md's topic table
    /// specifies this topic as `QoS 0, ~30s` and says nothing about a
    /// body, and `relay-core`'s `subscribeHeartbeat` ignores the payload
    /// entirely - arrival *is* the signal. Inventing a body here would
    /// create something a future relay might start parsing, for no
    /// current benefit (#142 acceptance criterion 6).
    ///
    /// QoS 0 (`TopicQos.heartbeatQos`), also from that table: an
    /// at-most-once beat is right for a signal that repeats every 30s
    /// and is only read as "recently alive" - redelivering a stale one
    /// would be actively misleading.
    public func publishHeartbeat() async throws {
        try await transport.publish(
            topic: Topics.heartbeat(account: accountId, node: nodeId),
            payload: "",
            qos: TopicQos.heartbeatQos,
            retained: false
        )
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
