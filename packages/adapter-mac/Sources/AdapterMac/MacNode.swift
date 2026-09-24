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
    ///
    /// Deliberately still the **observed audio route**, not the relay's
    /// holder, and #234 did not change that. The two answer different
    /// questions - "is the headset physically here" versus "does the
    /// relay believe it should be" - and the whole value of the status
    /// line is that it can disagree with the relay and so reveal a
    /// stuck handover. See ``holdsClaim()`` for the other one.
    public func status() -> NodeStatus {
        nodeStatus(isConnected: transport.isConnected(), holdsRoute: routeObserver?.holdsAudioRoute())
    }

    /// Whether the **relay** currently has this node as holder, or `nil`
    /// if it has not said (#234).
    ///
    /// This is what the menu's action label is derived from, because it
    /// is the only thing that answers "would tapping this claim or
    /// release?" without guessing. ``status()`` above is the physical
    /// counterpart and is not interchangeable with it.
    public func holdsClaim() -> Bool? {
        guard transport.isConnected() else { return nil }
        return holderState.holds(nodeId: nodeId)
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

    /// ADR 0022 (#254). Silences this device across the ~2.7s of a
    /// handover where no device holds the headset, so audio does not fall
    /// back to the built-in speakers. Defaults to a no-op, so a node
    /// built without one behaves exactly as it did before ADR 0022 -
    /// leaking that audio, as it always has, rather than refusing to
    /// hand over.
    private let audioGate: HandoverAudioGate

    /// #234 - the relay's holder, from the retained state topic. Fed by
    /// ``listenForState()``, read by ``holdsClaim()``.
    private let holderState = HolderState()

    public init(
        accountId: String,
        nodeId: String,
        headsetIdentifier: UUID,
        transport: MqttTransport,
        bluetooth: BluetoothConnectionManager,
        selfCooldown: SelfCooldown = SelfCooldown(),
        routeObserver: AudioRouteObserver? = nil,
        routeTransition: RouteTransition = RouteTransition(),
        sequenceGate: CommandSequenceGate = CommandSequenceGate(),
        audioGate: HandoverAudioGate = NoOpHandoverAudioGate()
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
        self.audioGate = audioGate
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
    ///
    /// Also **ends any manual claim this node was holding** (#234
    /// criterion 5). A relay-issued release means something outranked
    /// the user's claim - a call, or another node's manual claim - and
    /// the product decision is that the interruption *ends* the claim
    /// rather than suspending it. When the call finishes, the headset
    /// does not come back here; it follows the remaining triggers.
    ///
    /// ADR 0010's note that a manual claim persists "until a call
    /// outranks it" permits either reading. This is the one chosen, and
    /// it is chosen because the alternative is unpredictable in a way
    /// users do not forgive: a headset that silently reappears on a
    /// device minutes after an unrelated call ended, with no action from
    /// anyone, is indistinguishable from the oscillation bugs (#236,
    /// #251) this project has spent weeks removing.
    ///
    /// See ``endManualClaimIfHeld()`` for why this must be published and
    /// not merely forgotten locally.
    public func onRelease() async throws {
        await endManualClaimIfHeld()
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
                try await withHandoverAudioSuppressed(for: command.type) {
                    switch command.type {
                    case .claim: try await onClaim()
                    case .release: try await onRelease()
                    }
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
                    reason: timedOut ? nil : Self.failureReason(for: error),
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

    /// Which of ADR 0019's reason codes a failed command earned (#264).
    ///
    /// Everything used to flatten to `targetDeviceUnreachable`, which is
    /// the most common case but not the only one. The distinction that
    /// matters is **which end of the link failed**: a device that macOS
    /// has never paired, or an identifier carrying no Bluetooth address,
    /// says nothing about where the headset is. Recording those as "the
    /// headset did not answer" sends anyone reading the telemetry to look
    /// in the wrong place — and these are provisioning faults, which are
    /// permanent until someone fixes them, not the transient outage
    /// `targetDeviceUnreachable` implies.
    ///
    /// The default stays `targetDeviceUnreachable` rather than becoming
    /// "unknown": an unrecognised error out of a Bluetooth call is far
    /// more likely to be the headset than the stack, and ADR 0019 offers
    /// no code for "we are not sure". Adding one would need an ADR — the
    /// confirmed-outcome pattern is a frozen contract (AGENTS.md).
    ///
    /// Mirrors `AndroidNode.failureReasonFor`.
    private static func failureReason(for error: Error) -> CommandFailureReason {
        guard let gatewayError = error as? BluetoothGatewayError else { return .targetDeviceUnreachable }
        switch gatewayError {
        case .unrecognizedDeviceIdentifier, .deviceNotPaired:
            return .bluetoothUnavailable
        case .connectFailed, .disconnectFailed:
            // IOBluetooth's own answer that the baseband connect failed,
            // which for a headset that is off or in its case arrives via
            // its page timeout — comfortably inside #244's 8s bound, so
            // the Mac reaches this case rather than timing out. That is
            // why macOS needs no equivalent of Android's
            // `UNREACHABLE_AFTER_MS`: it is *told* the device did not
            // answer, where Android has to infer it from a profile that
            // never left DISCONNECTED.
            return .targetDeviceUnreachable
        }
    }

    /// Ends this node's `manual_claim`, if it had one, when the relay
    /// takes the headset away (#234 criterion 5).
    ///
    /// ## Forgetting it locally is not enough
    ///
    /// The obvious implementation - drop `manual_claim` from
    /// ``activeEvents`` and move on - silently implements the *opposite*
    /// decision. The relay keeps its own record of which triggers are
    /// active per node; if it is never told the claim ended, it still
    /// has `manual_claim` active here, and the moment the call that
    /// outranked it finishes, `computeActiveHolder` hands the headset
    /// straight back. The claim would be suspended, not ended, and
    /// nothing in this file would look wrong.
    ///
    /// So the end is published. ``endEvent(type:)`` does that, and is
    /// exempt from the self-cooldown (`manual_claim` bypasses it), so
    /// the publish is not swallowed by the window ``onRelease()`` is
    /// about to arm.
    ///
    /// ## Why a publish failure is not fatal
    ///
    /// ``endEvent(type:)`` removes the local entry **before** it
    /// publishes (#183), so a failed publish still leaves this node's
    /// own record correct, and the next periodic registration carries
    /// the corrected `activeEvents` to the relay - within one interval
    /// rather than never. Letting the error propagate instead would fail
    /// the release itself, which is far worse: the headset would stay
    /// connected here while the relay believed it had moved.
    private func endManualClaimIfHeld() async {
        guard activeEvents.contains(.manualClaim) else { return }
        do {
            try await endEvent(type: .manualClaim)
        } catch {
            logAdapterError(
                category: "MacNode",
                "could not publish the end of a revoked manual claim - registration will reconcile: "
                    + String(describing: error)
            )
        }
    }

    /// Subscribes to the retained state topic and keeps ``holdsClaim()``
    /// current (#234). Suspends until the stream ends, like
    /// ``listenForCommands()``.
    ///
    /// **This is a read of an already-frozen topic, not a protocol
    /// change.** The topic, its shape and its retained flag all predate
    /// this (ADR 0015, #229); nothing here publishes to it, and the
    /// relay is unchanged.
    ///
    /// Retained is what makes it useful to a menu-bar app: the broker
    /// replays the current holder the moment we subscribe, so the menu
    /// is correct on the first open after launch rather than only after
    /// the next handover. The Mac relaunches at every login (#144), so
    /// "only after the next handover" would be the common case.
    ///
    /// Unparseable payloads are skipped rather than thrown, for the same
    /// reason ``listenForCommands()`` skips them: a malformed message
    /// from a newer relay must not tear down the subscription and leave
    /// this node's menu frozen at a stale holder forever.
    public func listenForState() async throws {
        let states = transport.subscribe(
            topic: Topics.state(account: accountId, resource: Self.resource),
            qos: TopicQos.stateSubscribeQos
        )
        for await payload in states {
            guard let state = try? JSONDecoder().decode(StatePayload.self, from: Data(payload.utf8)) else {
                logAdapterError(category: "MacNode", "undecodable state payload - staying subscribed")
                continue
            }
            holderState.update(holder: state.holder)
        }
    }

    /// ``EventLifecycle`` conformance (#234): whether `type` is a trigger
    /// this node has reported and not yet ended.
    ///
    /// Added so ``ManualClaim`` can stop keeping its own boolean. Two
    /// records of one fact is what #234's second symptom actually was -
    /// a relay-issued release cleared the node's view and left the
    /// menu's view untouched, so the menu offered "Release Headset" for
    /// a claim that no longer existed anywhere else.
    public func isEventActive(_ type: EventKind) -> Bool {
        activeEvents.contains(type)
    }

    /// The trigger this node started most recently and has not ended, or
    /// `nil` if none is active (#234).
    ///
    /// Feeds the menu's "Holding - playing media" readout. Recency, not
    /// rank: see ``ActiveEventSet/mostRecent()``.
    public func mostRecentTrigger() -> EventKind? {
        activeEvents.mostRecent()
    }

    /// Runs the mechanical claim/release with this device's audio
    /// silenced (ADR 0022, #254).
    ///
    /// ## Why a closure rather than a `defer`
    ///
    /// ADR 0022's amendment asks for restore-in-a-`defer`, and that is
    /// the right shape - but Swift's `defer` body cannot `await`, and
    /// ``HandoverAudioGate/restore()`` is asynchronous. This is the
    /// closure-scoped equivalent: every way out of `body` - returning,
    /// throwing, and the cancellation rethrow - passes through a restore
    /// below. The Kotlin side gets the same guarantee from explicit
    /// calls on each path in `AndroidNode`'s command loop; keep the two
    /// in step.
    ///
    /// ## Why release does not restore
    ///
    /// Asymmetric on purpose. A release means the user has moved to
    /// another device, so this one stays silent until it is claimed
    /// again - and the claim's ``HandoverAudioGate/silence()`` is a
    /// no-op that keeps the record it already holds, so the eventual
    /// restore still returns the original volume rather than zero.
    private func withHandoverAudioSuppressed(
        for type: CommandType,
        _ body: () async throws -> Void
    ) async rethrows {
        await audioGate.silence()
        do {
            try await body()
        } catch {
            if type == .claim { await audioGate.restore() }
            throw error
        }
        if type == .claim { await audioGate.restore() }
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
