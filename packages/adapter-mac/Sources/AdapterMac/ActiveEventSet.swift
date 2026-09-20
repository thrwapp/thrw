import Foundation

/// The triggers a node has reported and not yet ended (#178).
///
/// Sent with every registration (`RegistrationPayload.activeEvents`) so a
/// relay that lost its state - by restarting, or by its MQTT connection
/// dropping and reconnecting - can reconcile to what is actually true
/// rather than inferring it from a stream of edges it may have missed.
///
/// Insertion order is preserved so the payload reads in the order the
/// triggers actually started. The relay does not depend on that (it keeps
/// its own ordering for the "most recently started wins" tie-break, and
/// deliberately does not re-stamp it on reconciliation), but it makes the
/// wire messages far easier to read when debugging against a live relay.
///
/// `@unchecked Sendable` with an `NSLock`, the same as ``SelfCooldown``
/// and for the same reason: it is mutated from whichever task publishes
/// an event and read from the task that registers, so it needs to be
/// safe across both without forcing either to be an actor.
final class ActiveEventSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ordered: [EventKind] = []

    func insert(_ kind: EventKind) {
        lock.lock()
        defer { lock.unlock() }
        guard !ordered.contains(kind) else { return }
        ordered.append(kind)
    }

    func remove(_ kind: EventKind) {
        lock.lock()
        defer { lock.unlock() }
        ordered.removeAll { $0 == kind }
    }

    func snapshot() -> [EventKind] {
        lock.lock()
        defer { lock.unlock() }
        return ordered
    }
}
