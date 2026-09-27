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

/// How long a single transition may stay open before it is written off
/// as stuck (#303).
///
/// Derived rather than picked: no legitimate transition can outlast the
/// command bound ADR 0019 puts on the work inside it
/// (``commandOutcomeTimeout``), plus the settle tail that follows it
/// (``defaultRouteSettle``). Anything still open past both has not
/// finished late - it is never going to finish.
///
/// This exists because a transition that never ends is not a slow
/// transition, it is an invisible node. While one is open this node
/// reports `observedRoutes: {}` - "no information", which ADR 0018 tells
/// the relay to omit rather than act on - and ignores its own triggers.
/// On the reference Mac that state held for seventeen minutes, ended
/// only by quitting the app, while the relay went on believing a node
/// that did not hold the route was the holder and logged
/// `reassert_exhausted` at it every two minutes.
public let defaultRouteTransitionCeiling: Duration = commandOutcomeTimeout + defaultRouteSettle

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
    private let ceiling: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var inProgress = 0
    private var settledUntil: ContinuousClock.Instant?
    /// When the outermost currently-open transition began - the clock the
    /// ceiling is measured against. `nil` whenever nothing is open.
    private var openedAt: ContinuousClock.Instant?

    public init(
        settle: Duration = defaultRouteSettle,
        ceiling: Duration = defaultRouteTransitionCeiling,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.settle = settle
        self.ceiling = ceiling
        self.now = now
    }

    /// A claim or release has started.
    public func begin() {
        lock.lock()
        // Only the outermost begin starts the clock: the counter nests
        // (`withHandoverAudioSuppressed` opens one and `onClaim` opens
        // another inside it), and restarting it on the inner begin would
        // let a stuck transition extend its own deadline.
        let opening = inProgress == 0
        if opening { openedAt = now() }
        inProgress += 1
        lock.unlock()
        // #303 criterion 5. Nothing under `Route/` logged anything, so
        // the Mac's whole side of that wedge had to be inferred from
        // relay traffic. Only the outer edges are logged, not every
        // nested begin: two lines per command, which is what makes a
        // transition that never closed visible as an opened line with no
        // closed line after it.
        if opening { logAdapterInfo(category: "RouteTransition", "transition opened") }
    }

    /// It finished - the route may still be catching up.
    public func end() {
        lock.lock()
        if inProgress > 0 { inProgress -= 1 }
        let closing = inProgress == 0
        let openFor = closing ? openedAt?.duration(to: now()) : nil
        if closing { openedAt = nil }
        settledUntil = now().advanced(by: settle)
        lock.unlock()
        if closing {
            let took = openFor.map { "after \($0)" } ?? "(never opened)"
            logAdapterInfo(
                category: "RouteTransition",
                "transition closed \(took) - settling for \(settle)"
            )
        }
    }

    /// True while a transition is running *or* still settling. A route
    /// observation taken now means nothing and must be omitted rather
    /// than reported.
    public func isSettling() -> Bool {
        lock.lock()
        let abandoned = abandonIfStuckLocked()
        let settling: Bool
        if inProgress > 0 {
            settling = true
        } else if let until = settledUntil {
            settling = now() < until
        } else {
            settling = false
        }
        lock.unlock()
        report(abandoned)
        return settling
    }

    /// True only while a command is actually executing — **not** during
    /// the settle tail (#295).
    ///
    /// A narrower question with a different answer, for a different
    /// consumer. ``isSettling()`` asks *"could a route observation be
    /// misleading?"*, which stays true for six seconds after the work
    /// finishes because the route is still moving. This asks *"is thrw
    /// currently doing something to this device's audio?"*, which stops
    /// being true the moment it stops doing it.
    ///
    /// Triggers are ignored while this is true, because ADR 0022's audio
    /// gate pauses and resumes playback to cover the handover — and the
    /// media trigger reads exactly that. Without it, thrw reads its own
    /// suppression as the user stopping their music.
    public func isExecuting() -> Bool {
        lock.lock()
        let abandoned = abandonIfStuckLocked()
        let executing = inProgress > 0
        lock.unlock()
        report(abandoned)
        return executing
    }

    /// Writes off a transition that has been open past ``ceiling`` and
    /// returns how long it had been open, or `nil` if there was nothing
    /// to write off.
    ///
    /// Lazy rather than timer-driven on purpose: the two questions this
    /// type answers are asked on the node's own schedule - every
    /// registration (~120s), every heartbeat, every trigger - so the
    /// state repairs itself the next time anything cares, with no task
    /// to own, cancel or leak.
    ///
    /// Resetting rather than merely answering "not settling" is the part
    /// that matters. Leaving the counter raised would mean the next
    /// legitimate claim begins at `inProgress == 1`, never restarts
    /// ``openedAt``, and is therefore treated as already expired - a node
    /// that had lost its settle protection permanently. And
    /// ``settledUntil`` is cleared rather than extended: after this long
    /// the route is not still moving, and the node's whole problem is
    /// that it has been saying nothing.
    ///
    /// The caller's stuck work is *not* cancelled here, because this type
    /// holds no handle on it and inventing one would be a lie - see
    /// ``withBluetoothTimeout``, which is what actually unsticks the
    /// command. This is the containment: even if some future path latches
    /// the counter again, the node goes back to telling the truth on its
    /// own, without a restart.
    private func abandonIfStuckLocked() -> Duration? {
        guard inProgress > 0, let openedAt else { return nil }
        let openFor = openedAt.duration(to: now())
        guard openFor > ceiling else { return nil }
        inProgress = 0
        self.openedAt = nil
        settledUntil = nil
        return openFor
    }

    private func report(_ abandoned: Duration?) {
        guard let abandoned else { return }
        logAdapterError(
            category: "RouteTransition",
            "transition open for \(abandoned) - past the \(ceiling) ceiling, writing it off so this node reports its route again (#303)"
        )
    }
}
