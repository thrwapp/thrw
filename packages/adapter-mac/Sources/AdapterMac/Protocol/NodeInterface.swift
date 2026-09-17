import Foundation

/// Mirror of `packages/protocol`'s `type Priority = number`.
public typealias Priority = Int

/// Mirror of `packages/protocol`'s `EventKind` union - the trigger
/// categories from architecture.md's "Priority rules" section. The raw
/// values are the wire format and must stay byte-identical to the
/// TypeScript union members `"call" | "manual_claim" | "voip" | "media"`.
///
/// Note the *ranking* of these kinds is deliberately not mirrored here:
/// architecture.md requires priority rules to live server-side in the
/// relay, "never duplicated in adapters".
public enum EventKind: String, Codable, Sendable {
    case call
    case manualClaim = "manual_claim"
    case voip
    case media
}

/// Mirror of `packages/protocol`'s `NodeManifest["platform"]` union.
public enum Platform: String, Codable, Sendable {
    case android
    case mac
    case ipad
    case linux
}

/// Mirror of `packages/protocol`'s `NodeManifest` - same field names,
/// same order. This is what the relay's device registry
/// (`packages/relay-core/src/device-registry.ts`) stores verbatim, so
/// the JSON field names here have to match the TypeScript interface
/// exactly.
public struct NodeManifest: Codable, Sendable, Equatable {
    public let nodeId: String
    public let platform: Platform
    public let displayName: String
    public let adapterVersion: String
    public let supportedEventKinds: [EventKind]

    public init(
        nodeId: String,
        platform: Platform,
        displayName: String,
        adapterVersion: String,
        supportedEventKinds: [EventKind]
    ) {
        self.nodeId = nodeId
        self.platform = platform
        self.displayName = displayName
        self.adapterVersion = adapterVersion
        self.supportedEventKinds = supportedEventKinds
    }
}

/// Mirror of `packages/protocol`'s `NodeInterface`, the shared node
/// interface from architecture.md's "System components" section - same
/// four methods as `adapter-android/protocol/NodeInterface.kt`'s own
/// mirror.
///
/// Deliberately *not* here: the connection state machine (idle /
/// pre-claim / claim / active). That is a frozen contract per ADR 0010 /
/// 0011 / 0013 and needs its own ADR plus human review - the TypeScript
/// `NodeInterface` leaves it out for the same reason, and so does the
/// Kotlin mirror.
///
/// The one intentional difference from the TypeScript shape (same
/// difference the Kotlin mirror makes): these are `async throws` rather
/// than `void`-returning. Every one of them does I/O (an MQTT publish, or
/// a Bluetooth connect/disconnect through `BluetoothConnectionManager`,
/// whose methods are already `async throws`), and AGENTS.md's
/// conventions require Swift 6 concurrency features where applicable.
public protocol NodeInterface: Sendable {
    func register(manifest: NodeManifest) async throws

    func emitEvent(type: EventKind, priority: Priority) async throws

    func onClaim() async throws

    func onRelease() async throws
}
