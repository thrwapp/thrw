import Foundation

/// 6 seconds, per ADR 0010's 2026-09-23 amendment. `adapter-android`'s
/// `SelfCooldown.DEFAULT_WINDOW_MS` is the same constant on the other
/// side of the same behaviour - change both together.
///
/// **Was 3 seconds, which was too short (#251).** ADR 0010 estimated
/// "~3 seconds" as how long thrw's own side effect takes to play out;
/// ADR 0018 later *measured* a claim taking 3-5s to move the route. So
/// the window closed before the transition it exists to cover had
/// finished, and the tail of that transition was read as a fresh
/// trigger.
///
/// What that looked like on hardware: media playing on both devices,
/// and the Mac emitting `media` start/end pairs 1-5 seconds apart while
/// YouTube played continuously. Since the tie-break is
/// most-recently-started, each restart took the headset back and each
/// end handed it to the phone - bouncing indefinitely, with the relay
/// arbitrating correctly the whole time.
///
/// 6s covers ADR 0018's measured upper bound with margin and stays
/// clear of ADR 0019's 8s command bound, so the two do not interact
/// confusingly.
public let defaultSelfCooldown: Duration = .seconds(6)

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
