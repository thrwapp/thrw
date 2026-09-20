import Foundation

/// How long after a claim or release the route may still be catching up.
///
/// Six seconds: comfortably past the 3-5s settle measured on the
/// reference hardware, without being so long that a node stays
/// unreconcilable for a meaningful slice of the 2-minute registration
/// cadence. Derived from measurement rather than chosen - see
/// `docs/testing/compatibility-matrix.md`. `adapter-android`'s
/// `RouteTransition.DEFAULT_SETTLE_MS` is the same constant.
public let defaultRouteSettle: Duration = .seconds(6)

/// Tracks whether a claim or release is still settling, so route
/// observations taken mid-transition are not reported as fact (#191, ADR
/// 0018 decision 2).
///
/// Moving the audio route is not instantaneous. A claim takes 3-5 seconds
/// for the headset to actually become the default output device. A
/// reconciliation snapshot inside that window reports "I do not hold
/// this" while the relay correctly believes the node does - and the
/// relay, seeing a disagreement, would correct a transition that was
/// simply still happening. On a 2-minute cadence that is a permanent
/// oscillation generator.
///
/// ## Why not reuse ``SelfCooldown``
///
/// It answers a different question and its window is load-bearing at its
/// current value. The cooldown suppresses *triggers* caused by thrw's own
/// action, and its 3 seconds is what stops a released device re-claiming
/// on its own continuing audio - verified on hardware. The claim side
/// settles later than that (the media monitor was observed re-firing at
/// +4s and +5s, outside the cooldown), so widening the cooldown to cover
/// route settling would change behaviour that is already correct.
public final class RouteTransition: @unchecked Sendable {
    private let lock = NSLock()
    private let settle: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var inProgress = 0
    private var settledUntil: ContinuousClock.Instant?

    public init(
        settle: Duration = defaultRouteSettle,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.settle = settle
        self.now = now
    }

    /// A claim or release has started.
    public func begin() {
        lock.lock()
        inProgress += 1
        lock.unlock()
    }

    /// It finished - the route may still be catching up.
    public func end() {
        lock.lock()
        if inProgress > 0 { inProgress -= 1 }
        settledUntil = now().advanced(by: settle)
        lock.unlock()
    }

    /// True while a transition is running *or* still settling. A route
    /// observation taken now means nothing and must be omitted rather
    /// than reported.
    public func isSettling() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inProgress > 0 { return true }
        guard let until = settledUntil else { return false }
        return now() < until
    }
}
