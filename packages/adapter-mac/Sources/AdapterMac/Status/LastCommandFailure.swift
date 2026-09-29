import Foundation

/// A claim or release this node was told to perform and could not (#309).
///
/// Structured rather than a formatted string: the node records what
/// happened, the UI decides how to say it. `AppDelegate` is the only
/// consumer today and a Settings window would be the second.
public struct CommandFailure: Sendable, Equatable {
    public let type: CommandType
    /// `.failed` or `.timedOut` — never `.succeeded`.
    public let outcome: CommandOutcome
    /// Absent for a timeout: ADR 0019 separates "the headset said no"
    /// from "nothing answered at all", and only the first has a reason.
    public let reason: CommandFailureReason?

    public init(type: CommandType, outcome: CommandOutcome, reason: CommandFailureReason?) {
        self.type = type
        self.outcome = outcome
        self.reason = reason
    }
}

/// The most recent command failure, or none since the last success.
///
/// ## Why this exists
///
/// Before #309 a failed command reached `logAdapterError` and stopped
/// there. The relay learned about it — ADR 0019's outcome is published
/// either way — but the person holding the device did not, and the menu
/// went on reading exactly as it had. `scenarios.md`'s R3 ("headset in
/// its case or out of range when a claim is made") requires that the
/// user is told; this is what the UI reads to tell them.
///
/// ## Cleared by success, not by a timer
///
/// A failure notice that expires on a clock would claim things are fine
/// while they are still broken. Clearing on the next *successful*
/// command means the readout is only ever "the last thing thrw tried to
/// do failed" or nothing — the same rule the status line follows after
/// #213 replaced its static blurb.
///
/// `@unchecked Sendable` with an `NSLock`, matching ``ActiveEventSet``
/// and ``SelfCooldown``: written from the command loop, read from the
/// main actor when a menu opens.
public final class LastCommandFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: CommandFailure?

    public init() {}

    public func record(_ failure: CommandFailure) {
        lock.lock()
        defer { lock.unlock() }
        self.failure = failure
    }

    /// A command succeeded, so whatever failed before is no longer the
    /// most recent thing that happened.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        failure = nil
    }

    public func current() -> CommandFailure? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}
