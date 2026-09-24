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

    func contains(_ kind: EventKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ordered.contains(kind)
    }

    func snapshot() -> [EventKind] {
        lock.lock()
        defer { lock.unlock() }
        return ordered
    }

    /// The trigger that started most recently, or `nil` if none is
    /// active.
    ///
    /// Recency, **not** rank. Adapters do not rank triggers -
    /// architecture.md puts priority rules server-side, "never
    /// duplicated in adapters" - and this deliberately reads the
    /// insertion order this type already preserves rather than
    /// consulting anything resembling `PRIORITY_ORDER`. It exists so the
    /// menu can say *why* this device is holding the headset (#234)
    /// without the adapter forming an opinion about which trigger would
    /// win.
    func mostRecent() -> EventKind? {
        lock.lock()
        defer { lock.unlock() }
        return ordered.last
    }
}
