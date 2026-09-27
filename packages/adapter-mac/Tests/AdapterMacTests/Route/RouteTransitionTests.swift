import XCTest

@testable import AdapterMac

/// ``RouteTransition``'s first tests (#303). It had none, and what it did
/// wrong cost a seventeen-minute wedge on the reference Mac: a counter
/// raised by a command that never returned, holding the node in "no
/// information" and making it ignore its own triggers until the app was
/// quit.
///
/// Every test drives an injected clock, so none of them waits on wall
/// time.
final class RouteTransitionTests: XCTestCase {
    /// A settable ``ContinuousClock`` instant. `@unchecked Sendable` with
    /// a lock for the same reason the type under test is.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now

        var now: ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }

        func advance(by duration: Duration) {
            lock.lock()
            instant = instant.advanced(by: duration)
            lock.unlock()
        }
    }

    private func make(
        settle: Duration = defaultRouteSettle,
        ceiling: Duration = defaultRouteTransitionCeiling
    ) -> (RouteTransition, TestClock) {
        let clock = TestClock()
        let transition = RouteTransition(settle: settle, ceiling: ceiling, now: { clock.now })
        return (transition, clock)
    }

    // MARK: - the behaviour that was already there

    func testNothingIsSettlingBeforeAnyTransition() {
        let (transition, _) = make()

        XCTAssertFalse(transition.isSettling())
        XCTAssertFalse(transition.isExecuting())
    }

    func testAnOpenTransitionIsBothSettlingAndExecuting() {
        let (transition, _) = make()

        transition.begin()

        XCTAssertTrue(transition.isSettling())
        XCTAssertTrue(transition.isExecuting())
    }

    /// The distinction #295 turns on: the settle tail outlasts the work,
    /// and only the work suppresses triggers.
    func testAfterEndTheSettleTailIsStillSettlingButNotExecuting() {
        let (transition, clock) = make(settle: .seconds(6))

        transition.begin()
        transition.end()

        XCTAssertTrue(transition.isSettling())
        XCTAssertFalse(transition.isExecuting())

        clock.advance(by: .seconds(7))
        XCTAssertFalse(transition.isSettling())
    }

    // MARK: - the ceiling (#303)

    func testATransitionStillInsideTheCeilingIsLeftAlone() {
        let (transition, clock) = make(ceiling: .seconds(14))

        transition.begin()
        clock.advance(by: .seconds(13))

        XCTAssertTrue(transition.isSettling(), "13s is a slow claim, not a stuck one")
        XCTAssertTrue(transition.isExecuting())
    }

    /// The heart of #303. A transition that never closed used to hold
    /// both answers `true` forever; now it is written off, which is what
    /// puts the node back to reporting its route and reading its own
    /// triggers **without a restart**.
    func testATransitionOpenPastTheCeilingIsWrittenOff() {
        let (transition, clock) = make(ceiling: .seconds(14))

        transition.begin()
        clock.advance(by: .seconds(15))

        XCTAssertFalse(transition.isSettling(), "a transition open past the ceiling is stuck, not settling")
        XCTAssertFalse(transition.isExecuting())
    }

    /// Writing off has to *reset*, not merely answer "false". Leaving the
    /// counter raised would mean the next real claim began at 1, never
    /// restarted the clock, and was treated as already expired - a node
    /// that had permanently lost its settle protection, which is ADR
    /// 0018 decision 2 silently switched off.
    func testAfterAWriteOffTheNextTransitionIsProtectedAgain() {
        let (transition, clock) = make(settle: .seconds(6), ceiling: .seconds(14))

        transition.begin()
        clock.advance(by: .seconds(15))
        XCTAssertFalse(transition.isExecuting())

        transition.begin()
        XCTAssertTrue(transition.isExecuting(), "the write-off must not cost the node its next transition")
        XCTAssertTrue(transition.isSettling())
    }

    /// The counter nests - `withHandoverAudioSuppressed` opens one and
    /// `onClaim` opens another inside it - so the ceiling is measured
    /// from the outermost begin. Restarting it on the inner one would let
    /// a stuck transition extend its own deadline.
    func testANestedBeginDoesNotExtendTheCeiling() {
        let (transition, clock) = make(ceiling: .seconds(14))

        transition.begin()
        clock.advance(by: .seconds(10))
        transition.begin()
        clock.advance(by: .seconds(5))

        XCTAssertFalse(transition.isExecuting(), "15s from the outer begin is past the ceiling")
    }

    /// The abandoned command can still return eventually. Its `end()`
    /// must not push the counter negative or re-raise it.
    func testAnEndArrivingAfterAWriteOffIsHarmless() {
        let (transition, clock) = make(settle: .seconds(6), ceiling: .seconds(14))

        transition.begin()
        clock.advance(by: .seconds(15))
        XCTAssertFalse(transition.isExecuting())

        transition.end()

        XCTAssertFalse(transition.isExecuting())
        XCTAssertTrue(transition.isSettling(), "end always starts a settle tail")
        clock.advance(by: .seconds(7))
        XCTAssertFalse(transition.isSettling())
    }

    /// The ceiling is derived, not chosen: the command bound plus the
    /// settle tail. Asserted so a change to either constant has to be
    /// deliberate here too.
    func testTheDefaultCeilingIsTheCommandBoundPlusTheSettleTail() {
        XCTAssertEqual(defaultRouteTransitionCeiling, commandOutcomeTimeout + defaultRouteSettle)
    }
}
