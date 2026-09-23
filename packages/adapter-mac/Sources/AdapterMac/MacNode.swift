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
    /// The resource this adapter manages (ADR 0015 / #171).
    ///
    /// A constant rather than a parameter: this adapter controls the
    /// headset audio connection and nothing else, which is exactly what
    /// its manifest declares. A `hid` adapter would be a different node.
    static let resource: ResourceType = .audio

    private let accountId: String
    private let nodeId: String
    private let headsetIdentifier: UUID
    private let transport: MqttTransport
    private let bluetooth: BluetoothConnectionManager
    /// ADR 0010 point 1 (#167) - armed by ``onClaim()``/``onRelease()``.
    private let selfCooldown: SelfCooldown

    /// This node's current status, for display (#213).
    ///
    /// Asks the transport and the route observer directly rather than
    /// caching: a cached status is exactly what goes stale during the
    /// silent failures this is meant to expose.
    public func status() -> NodeStatus {
        nodeStatus(isConnected: transport.isConnected(), holdsRoute: routeObserver?.holdsAudioRoute())
    }

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

    /// #191 - reads whether this Mac currently holds the audio route.
    /// Optional: a node built without one simply reports no observation,
    /// which the relay treats as "no information" rather than as "no".
    private let routeObserver: AudioRouteObserver?

    /// #191 - suppresses route observations taken mid-transition.
    private let routeTransition: RouteTransition

    /// ADR 0018 decision 1 (#210). Discards a relay command that is
    /// older than one this node has already acted on. Defaults to an
    /// in-memory mark so tests and a node built without persistence
    /// still work; `AppDelegate` supplies the `UserDefaults`-backed
    /// one, which is what makes the guarantee survive a relaunch.
    private let sequenceGate: CommandSequenceGate

    public init(
        accountId: String,
        nodeId: String,
        headsetIdentifier: UUID,
        transport: MqttTransport,
        bluetooth: BluetoothConnectionManager,
        selfCooldown: SelfCooldown = SelfCooldown(),
        routeObserver: AudioRouteObserver? = nil,
        routeTransition: RouteTransition = RouteTransition(),
        sequenceGate: CommandSequenceGate = CommandSequenceGate()
    ) {
        self.accountId = accountId
        self.nodeId = nodeId
        self.headsetIdentifier = headsetIdentifier
        self.transport = transport
        self.bluetooth = bluetooth
        self.selfCooldown = selfCooldown
        self.routeObserver = routeObserver
        self.routeTransition = routeTransition
        self.sequenceGate = sequenceGate
    }

    /// Publishes this node's manifest so the relay's device registry
    /// knows what the node can do. Rides the node's events topic (the
    /// only node-publishes topic in the frozen topic set) inside a
    /// `RegistrationPayload` envelope - see docs/handoffs/67.md.
    public func register(manifest: NodeManifest) async throws {
        try await publishToEvents(
            RegistrationPayload(
                manifest: manifest,
                activeEvents: activeEvents.snapshot(),
                observedRoutes: observedRoutes()
            )
        )
    }

    /// Publishes a trigger to the events topic at QoS 1 per `TopicQos`.
    public func emitEvent(type: EventKind, priority: Priority) async throws {
        if selfCooldown.isActive(), !type.bypassesSelfCooldown { return }
        try await publishToEvents(EventPayload(type: type, priority: priority))
        activeEvents.insert(type)
    }

    /// The symmetric partner of ``emitEvent(type:priority:)``: the `type`
    /// trigger this node reported has stopped. Publishes an
    /// `EventEndPayload` on the same events topic at the same QoS -
    /// mirrors `AndroidNode.kt`'s own `endEvent` (#68).
    public func endEvent(type: EventKind) async throws {
        // Forgotten locally **before** the cooldown check, and regardless
        // of whether it is published (#183).
        //
        // The trigger really has ended - the monitor has already cleared
        // its own flag and will never retry. If a suppressed end also
        // left this entry in place, the node would keep reporting the
        // trigger as active on every periodic registration, and #178's
        // reconciliation would *perpetuate* the stranded signal rather
        // than repair it. For `call` that is the highest-priority signal
        // in the system, pinned to this device indefinitely.
        //
        // Removing it instead creates a deliberate, temporary divergence:
        // the relay still believes the trigger is active, this node says
        // otherwise, and the next registration settles it in favour of
        // the truth - within one interval rather than never.
        activeEvents.remove(type)
        if selfCooldown.isActive(), !type.bypassesSelfCooldown { return }
        try await publishToEvents(EventEndPayload(type: type))
    }

    /// This node's observed audio route (#191), or an empty map when it
    /// cannot honestly be reported.
    ///
    /// Omitted in three cases, all meaning "no information" rather than
    /// "no": no observer was supplied, the route cannot be read, or a
    /// claim/release is still settling. A snapshot taken mid-transition
    /// reports "I do not hold this" while the relay correctly believes
    /// this node does, and the relay would then correct a transition that
    /// was simply still happening - on a 2-minute cadence, forever.
    private func observedRoutes() -> [String: Bool] {
        guard !routeTransition.isSettling(), let holds = routeObserver?.holdsAudioRoute() else {
            return [:]
        }
        return [resourceAudio: holds]
    }

    /// Claim won: connect the headset to this device.
    public func onClaim() async throws {
        routeTransition.begin()
        defer {
            routeTransition.end()
            selfCooldown.arm()
        }
        try await bluetooth.connect(deviceIdentifier: headsetIdentifier)
    }

    /// Claim lost (or released): disconnect the headset from this device.
    public func onRelease() async throws {
        routeTransition.begin()
        defer {
            routeTransition.end()
            selfCooldown.arm()
        }
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
    ///
    /// **A command that fails is skipped for the same reason** (#223). A
    /// headset that is off, out of range, busy, or simply does not
    /// support what was asked makes `onClaim`/`onRelease` throw, and
    /// before #223 that propagated out of here and ended the loop for
    /// good - `NodeRuntime` logged it and the task finished, nothing
    /// resubscribed, and `onReconnected` only re-registers. One failed
    /// claim left this Mac silently deaf to every later command until
    /// the app was relaunched, while its menu bar still said
    /// "Connected".
    ///
    /// `adapter-android` has had this since #161, where the unhandled
    /// version was worse still: it took the whole adapter process down
    /// on real hardware and Android restarted it in a loop. macOS fails
    /// more quietly, which is most likely why it went unnoticed.
    ///
    /// `CancellationError` is deliberately not swallowed: that is the
    /// runtime shutting this task down (`NodeRuntimeHandle.cancel()`, or
    /// app quit), not a Bluetooth failure, and catching it would break
    /// cancellation.
    public func listenForCommands() async throws {
        let commands = transport.subscribe(
            topic: Topics.commands(account: accountId, node: nodeId, resource: Self.resource),
            qos: TopicQos.commandsQos
        )
        for await payload in commands {
            guard let command = try? JSONDecoder().decode(CommandPayload.self, from: Data(payload.utf8)) else {
                continue
            }
            // ADR 0018 decision 1 (#210). Commands ride QoS 1, so the
            // broker may redeliver - and does, on reconnect. Acting on
            // a redelivered claim that arrives after a newer release
            // would take the headset back from whoever now holds it.
            guard sequenceGate.accepts(command) else {
                // ADR 0019 / #206. A command the gate discards is
                // reported, not dropped silently - that is exactly what
                // `superseded_by_newer_command` exists for, and ADR 0019
                // tracks it separately from real failures because a
                // superseded command is idempotency working correctly,
                // not a switch that went wrong.
                await reportOutcome(
                    command: command,
                    outcome: .failed,
                    reason: .supersededByNewerCommand,
                    durationMs: 0
                )
                continue
            }
            // ADR 0019's durationMs. A monotonic clock, not wall time:
            // this number feeds a latency SLO (ADR 0007), and an NTP step
            // mid-claim would otherwise produce a negative or wildly
            // inflated reading that silently skews it.
            let startedAt = ContinuousClock.now
            do {
                switch command.type {
                case .claim: try await onClaim()
                case .release: try await onRelease()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // #223. Logged, not swallowed silently, and the mark is
                // deliberately left where it is: the command did not
                // happen, so the broker's QoS 1 redelivery must be free
                // to retry it (#210).
                logAdapterError(
                    category: "MacNode",
                    "command \(command.type) failed - staying subscribed: \(String(describing: error))"
                )
                // A timeout is its own outcome rather than a failure with
                // a reason: ADR 0019 separates "the headset said no" from
                // "nothing answered at all", and #244's bound is what
                // produces the second.
                let timedOut = error is BluetoothOperationTimedOut
                await reportOutcome(
                    command: command,
                    outcome: timedOut ? .timedOut : .failed,
                    reason: timedOut ? nil : .targetDeviceUnreachable,
                    durationMs: Self.elapsedMs(since: startedAt)
                )
                continue
            }
            // Only after the command actually succeeded - the `continue`
            // above skips this, so the mark stays where it is and the
            // broker's redelivery gets to retry.
            sequenceGate.record(command)
            await reportOutcome(
                command: command,
                outcome: .succeeded,
                reason: nil,
                durationMs: Self.elapsedMs(since: startedAt)
            )
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
            topic: Topics.events(account: accountId, node: nodeId, resource: Self.resource),
            payload: String(decoding: data, as: UTF8.self),
            qos: TopicQos.eventsQos,
            retained: false
        )
    }

    /// ADR 0019 / #206 stage 2 - tells the relay how a command ended.
    ///
    /// **Never throws, and never aborts the command loop.** A failure to
    /// report an outcome is a lost measurement; a failure to keep
    /// listening is a node that goes deaf, which is #223 all over again.
    /// Those are not remotely the same severity, so this swallows its
    /// own publish errors after logging them.
    ///
    /// Cancellation is the one exception: it is re-thrown implicitly by
    /// not being caught here, because `publishToEvents` propagates it
    /// and the caller's `catch is CancellationError` needs to see it.
    private func reportOutcome(
        command: CommandPayload,
        outcome: CommandOutcome,
        reason: CommandFailureReason?,
        durationMs: Int
    ) async {
        do {
            try await publishToEvents(
                CommandOutcomePayload(
                    epoch: command.epoch,
                    seq: command.seq,
                    resourceType: Self.resource.rawValue,
                    outcome: outcome,
                    reason: reason,
                    durationMs: durationMs
                )
            )
        } catch {
            logAdapterError(
                category: "MacNode",
                "could not report \(outcome.rawValue) outcome for \(command.type): \(String(describing: error))"
            )
        }
    }

    /// Whole milliseconds since `start`, floored at zero.
    ///
    /// `ContinuousClock` keeps counting across system sleep, which is
    /// what we want: a claim issued before the lid closed and completing
    /// after it opened really did take that long from the user's point
    /// of view, and hiding that would flatter the latency data.
    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let ms = elapsed.components.seconds * 1_000
            + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return Int(max(0, ms))
    }
}
