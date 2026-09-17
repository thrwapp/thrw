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

/// Mirror of relay-core's `CommandPayload`.
public struct CommandPayload: Codable, Sendable, Equatable {
    public let type: CommandType

    public init(type: CommandType) {
        self.type = type
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

    public init(manifest: NodeManifest) {
        self.kind = registrationKind
        self.manifest = manifest
    }
}
