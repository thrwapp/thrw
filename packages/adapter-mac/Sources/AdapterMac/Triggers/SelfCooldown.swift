import Foundation

/// ~3 seconds, per ADR 0010. `adapter-android`'s
/// `SelfCooldown.DEFAULT_WINDOW_MS` is the same constant on the other
/// side of the same behaviour - change both together.
public let defaultSelfCooldown: Duration = .seconds(3)

/// ADR 0010 point 1: after thrw initiates a claim or release, it
/// suppresses processing of its own resulting connection-state-changed
/// events for a short window, so it doesn't misread the side effects of
/// its own action as a new trigger. Swift mirror of
/// `adapter-android`'s `SelfCooldown.kt` - see that file for the full
/// reasoning.
///
/// Became necessary with the media triggers (#165/#166): thrw
/// disconnects the headset, macOS pauses playback because the output
/// device vanished, and the media monitor reports "media ended" - an
/// event caused entirely by thrw's own action.
///
/// **What it deliberately cannot do**: a time window is a heuristic, not
/// a causal link. Inside the window this cannot tell *"audio stopped
/// because we disconnected"* from *"the user pressed pause at that exact
/// moment"* - both are suppressed. That is the trade ADR 0010 chose.
///
/// Per ADR 0013 this is **not** a fifth connection state - it is
/// adapter-local bookkeeping layered around `onClaim`/`onRelease`.
/// Lock-guarded and `@unchecked Sendable`: ``MacNode`` is `Sendable`
/// (via ``NodeInterface``), and this holds mutable state. The lock makes
/// that genuinely safe rather than merely asserted - `onClaim` arms it
/// from the command task while a trigger monitor reads it from its own.
public final class SelfCooldown: @unchecked Sendable {
    private let lock = NSLock()
    private let window: Duration
    private let now: () -> ContinuousClock.Instant
    private var activeUntil: ContinuousClock.Instant?

    public init(
        window: Duration = defaultSelfCooldown,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.window = window
        self.now = now
    }

    /// Called immediately after thrw initiates a claim or release.
    public func arm() {
        lock.lock()
        defer { lock.unlock() }
        activeUntil = now().advanced(by: window)
    }

    /// Whether trigger reporting should currently be suppressed.
    public func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let activeUntil else { return false }
        return now() < activeUntil
    }
}
