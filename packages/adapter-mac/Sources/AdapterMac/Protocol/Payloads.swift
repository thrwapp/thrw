import Foundation

/// Wire payloads carried on the topics in `Topics`.
///
/// architecture.md and `packages/protocol` define the *topics*, not the
/// message bodies on them - the bodies were decided per-issue and are
/// mirrored exactly from `adapter-android/protocol/Payloads.kt`, which is
/// itself an exact mirror of what `packages/relay-core/src/mqtt-client.ts`
/// already publishes/consumes. `RegistrationPayload` rides the events
/// topic with a `kind` discriminator rather than getting a topic of its
/// own, since the topic set is frozen (see docs/handoffs/67.md for the
/// original reasoning, carried over unchanged here).

/// Mirror of relay-core's `EventPayload`.
public struct EventPayload: Codable, Sendable, Equatable {
    public let type: EventKind
    public let priority: Priority

    public init(type: EventKind, priority: Priority) {
        self.type = type
        self.priority = priority
    }
}

/// Mirror of relay-core's `CommandPayload["type"]` union.
public enum CommandType: String, Codable, Sendable {
    case claim
    case release
}

/// Mirror of relay-core's `SequencedCommandPayload`.
///
/// `seq` and `epoch` are optional so a command carrying neither still
/// decodes - Swift's synthesised decoding uses `decodeIfPresent` for an
/// Optional. That is not defensive padding: the relay half of #210
/// shipped before the adapter half, so a build of this adapter has
/// already run against a relay that stamped nothing, and
/// ``CommandSequenceGate`` treats an unsequenced command as acceptable
/// rather than discarding it.
public struct CommandPayload: Codable, Sendable, Equatable {
    public let type: CommandType

    /// Monotonic per (account, node, resource type), within one
    /// ``epoch``. See ``CommandSequenceGate`` for what this node does
    /// with it.
    public let seq: Int?

    /// The relay *process* that sent this. Changes on every relay
    /// restart, which is what stops the high-water mark deadlocking the
    /// system - see ``CommandSequenceGate``.
    public let epoch: String?

    public init(type: CommandType, seq: Int? = nil, epoch: String? = nil) {
        self.type = type
        self.seq = seq
        self.epoch = epoch
    }
}

/// The `kind` discriminator that distinguishes a registration envelope
/// from an ordinary event on the same events topic.
public let registrationKind = "register"

/// Registration envelope published on the node's own events topic - see
/// `Payloads.kt`'s own kdoc (`REGISTRATION_KIND`) for why this rides the
/// events topic with a discriminator rather than a topic of its own.
public struct RegistrationPayload: Codable, Sendable, Equatable {
    public let kind: String
    public let manifest: NodeManifest

    /// The triggers this node has active *right now* (#178).
    ///
    /// Registration is re-sent periodically, not only at startup, and
    /// carrying the active set is what lets a relay that restarted - or
    /// whose MQTT connection dropped and reconnected - recover a correct
    /// picture. Without it the relay would infer state from a stream of
    /// edges it may have missed, and a node mid-playback would stay
    /// invisible until it happened to stop.
    ///
    /// Sent on every registration, including the first, where it is empty.
    public let activeEvents: [EventKind]

    /// This node's observed **audio route** per resource type (#191),
    /// keyed by ADR 0015's resource-type vocabulary - only
    /// ``resourceAudio`` exists today.
    ///
    /// Keyed rather than a bare boolean so it survives the ADR 0015
    /// migration (#171) without a second payload change; that ADR is
    /// accepted, so this follows it rather than speculating.
    ///
    /// A resource is **absent** when its route cannot be determined, or
    /// while a claim or release is still settling. Absent means "no
    /// information" and leaves the relay's record alone; `false` asserts
    /// this node does not hold the resource and is grounds for corrective
    /// action. Reporting a guess as `false` would hand the relay a
    /// fabricated disagreement.
    public let observedRoutes: [String: Bool]

    public init(
        manifest: NodeManifest,
        activeEvents: [EventKind] = [],
        observedRoutes: [String: Bool] = [:]
    ) {
        self.kind = registrationKind
        self.manifest = manifest
        self.activeEvents = activeEvents
        self.observedRoutes = observedRoutes
    }
}

/// ADR 0015's resource type for the headset audio connection.
public let resourceAudio = "audio"

/// The `kind` discriminator for [EventEndPayload].
public let eventEndKind = "event_end"

/// "The trigger I reported earlier stopped", published on the node's own
/// events topic (#127) - mirrors `Payloads.kt`'s own `EventEndPayload`
/// (added there in #68). Same `kind`-discriminator trick as
/// `RegistrationPayload`, and for the same reason: the topic set is
/// frozen, so this rides the events topic rather than getting one of its
/// own. Carries no `priority`: ending a trigger needs only its kind.
public struct EventEndPayload: Codable, Sendable, Equatable {
    public let kind: String
    public let type: EventKind

    public init(type: EventKind) {
        self.kind = eventEndKind
        self.type = type
    }
}

public let commandOutcomeKind = "command_outcome"

/// ADR 0019 / #206 stage 2. How a claim or release actually ended.
///
/// Same `kind`-discriminator trick as ``RegistrationPayload`` and
/// ``EventEndPayload``, for the same reason: the topic set is frozen, so
/// this rides the events topic rather than getting one of its own.
/// Mirrors `packages/protocol`'s `CommandOutcomePayload` and
/// `adapter-android`'s own copy - three hand-written implementations of
/// one wire format, and nothing else catches them drifting.
///
/// `epoch` and `seq` identify *which* command this answers, reusing the
/// pair ADR 0018 point 1 added for idempotency (#210/#224). Optional for
/// exactly the reason ``CommandPayload``'s are: a command carrying
/// neither is still acted on, so an outcome for it must still be
/// reportable rather than silently dropped.
public struct CommandOutcomePayload: Codable, Sendable, Equatable {
    public let kind: String
    public let epoch: String?
    public let seq: Int?
    public let resourceType: String
    public let outcome: String
    public let reason: String?
    public let durationMs: Int

    public init(
        epoch: String?,
        seq: Int?,
        resourceType: String,
        outcome: CommandOutcome,
        reason: CommandFailureReason?,
        durationMs: Int
    ) {
        self.kind = commandOutcomeKind
        self.epoch = epoch
        self.seq = seq
        self.resourceType = resourceType
        self.outcome = outcome.rawValue
        self.reason = reason?.rawValue
        self.durationMs = durationMs
    }
}

/// Mirror of `packages/protocol`'s `CommandOutcome`.
public enum CommandOutcome: String, Sendable {
    case succeeded
    case failed
    case timedOut = "timed_out"
}

/// Mirror of `packages/protocol`'s `CommandFailureReason`.
///
/// **Only two of the three are emitted today, deliberately.**
/// Distinguishing `bluetooth_unavailable` from
/// `target_device_unreachable` needs the gateways to surface typed,
/// *comparable* errors, and they do not: macOS throws
/// `BluetoothGatewayError` cases about pairing, Android throws
/// `IllegalStateException` with prose in the message. Classifying each
/// platform by whatever it happens to throw would make one reason code
/// mean different things on each side - and ADR 0019's premise is that
/// an outcome means the same thing in every row, or the aggregate is
/// meaningless.
///
/// So both platforms report `target_device_unreachable` for any
/// non-timeout failure until the gateways can tell these apart. Coarse
/// and comparable beats precise and incomparable; typed gateway errors
/// are the follow-up that unlocks the finer split.
public enum CommandFailureReason: String, Sendable {
    case bluetoothUnavailable = "bluetooth_unavailable"
    case targetDeviceUnreachable = "target_device_unreachable"
    case supersededByNewerCommand = "superseded_by_newer_command"
}
