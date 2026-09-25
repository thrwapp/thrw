import Foundation

/// What the trigger detectors in this package need from a node: start a
/// trigger, and later say it stopped. Swift mirror of
/// `adapter-android/triggers/EventLifecycle.kt` - same reasoning for why
/// this lives here, adapter-side, rather than growing `NodeInterface`/
/// `packages/protocol`: that type is the frozen cross-platform contract,
/// and growing it needs an ADR plus human review (AGENTS.md), not a
/// routine agent PR. `MacNode` conforms to this directly (`emitEvent`'s
/// signature already matches `NodeInterface`'s own requirement, so one
/// method satisfies both protocols at once).
public protocol EventLifecycle: Sendable {
    /// A trigger of `type` just started on this node.
    func emitEvent(type: EventKind, priority: Priority) async throws

    /// The `type` trigger that was active on this node just stopped.
    func endEvent(type: EventKind) async throws

    /// Whether `type` is currently one of this node's active triggers
    /// (#234).
    ///
    /// Synchronous and non-throwing: it reads state the node already
    /// keeps for `RegistrationPayload.activeEvents`, so there is nothing
    /// to await and nothing to fail. ``ManualClaim`` reads this instead
    /// of tracking its own copy - see that type for what the second copy
    /// cost.
    func isEventActive(_ type: EventKind) -> Bool

    /// Every trigger currently active on this node (#290).
    ///
    /// ``ArbitrationPause`` has to end all of them, and cannot get there
    /// from ``isEventActive(_:)`` without enumerating `EventKind` itself
    /// — which would silently miss a kind added later. The node already
    /// keeps this list for `RegistrationPayload.activeEvents`, so asking
    /// it is both cheaper and harder to get wrong.
    func activeEventKinds() -> [EventKind]
}

/// The priority every trigger detector in this package reports.
///
/// Adapters do not rank triggers: "Priority rules live server-side in the
/// relay, never duplicated in adapters" (architecture.md). This constant
/// is one value for every kind, so no ranking is implied by, or can drift
/// in, this adapter - mirrors `adapter-android/triggers/EventLifecycle.kt`'s
/// own `UNRANKED_PRIORITY`.
public let unrankedPriority: Priority = 0
