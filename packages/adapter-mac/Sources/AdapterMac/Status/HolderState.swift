import Foundation

/// The relay's authoritative answer to "which node holds this resource",
/// as last seen on the retained state topic (#234).
///
/// ## Why this exists at all
///
/// Before #234 nothing in either adapter read relay state. The menu's
/// action label was derived from ``ManualClaim``'s own boolean, which is
/// written only when the user taps - so it answered *"did you tap Claim
/// on this device?"*, never *"does this device hold the headset?"* A node
/// holding via a `call`, `voip` or `media` trigger still offered "Claim
/// Headset", which is the symptom #234 was filed for.
///
/// The answer was already on the broker. #229 made the relay publish it
/// retained, so a subscriber gets the current holder immediately on
/// subscribe rather than waiting for the next change - which matters for
/// a menu-bar app that may start long after the last handover.
///
/// ## Three states, not two
///
/// `nil` from ``holds(nodeId:)`` means **we have not heard**, and it is
/// deliberately distinct from "somebody else holds it":
///
/// - Never subscribed, or subscribed and no retained message existed yet
///   (a fresh account that has never had a holder).
/// - The transport is down, so what we last heard may be arbitrarily
///   stale.
///
/// Collapsing that into `false` would make the menu assert something it
/// does not know, which is the failure ``NodeStatus`` already refuses to
/// commit (its `.unknown` case exists for exactly this reason). Callers
/// are expected to fall back to something honest rather than render a
/// guess.
///
/// `@unchecked Sendable` with an `NSLock`, like ``ActiveEventSet`` and
/// ``SelfCooldown``: written by the task draining the state
/// subscription, read by the main thread when the menu opens.
public final class HolderState: @unchecked Sendable {
    private let lock = NSLock()

    /// Separate from `holder` on purpose - see the three-states note
    /// above. `false` here beats any value of `holder`.
    private var heard = false
    private var holder: String?

    public init() {}

    /// A retained state message arrived. `holder` may legitimately be
    /// `nil`: that is the relay saying nobody holds this resource.
    public func update(holder: String?) {
        lock.lock()
        defer { lock.unlock() }
        heard = true
        self.holder = holder
    }

    /// Whether `nodeId` is the current holder, or `nil` if the relay has
    /// not told us.
    public func holds(nodeId: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard heard else { return nil }
        return holder == nodeId
    }

    /// The current holder's node id, `nil` if nobody holds it, and
    /// `.none` wrapped twice if we have not heard - exposed for tests
    /// and diagnostics rather than for the menu, which wants
    /// ``holds(nodeId:)``.
    public func currentHolder() -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return heard ? .some(holder) : .none
    }

    /// Forgets what we were told, returning to "we have not heard".
    ///
    /// Called when the transport drops (#182): a retained value we
    /// received before a disconnect says what was true then, and the
    /// whole point of the `nil` state is to avoid presenting a stale
    /// belief as current. ``NodeStatus/disconnected`` already outranks
    /// holder state in the status line for the same reason.
    public func forget() {
        lock.lock()
        defer { lock.unlock() }
        heard = false
        holder = nil
    }
}
