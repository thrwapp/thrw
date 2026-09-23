import XCTest

@testable import AdapterMac

/// Mirrors `adapter-android`'s `SelfCooldownTest.kt` case-for-case - the
/// same window has to behave the same on both platforms.
final class SelfCooldownTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        var instant = ContinuousClock.now
        func read() -> ContinuousClock.Instant { instant }
    }

    func testInactiveBeforeAnythingIsArmed() {
        let clock = FakeClock()
        XCTAssertFalse(SelfCooldown(window: .seconds(3), now: clock.read).isActive())
    }

    func testActiveImmediatelyAfterArming() {
        let clock = FakeClock()
        let cooldown = SelfCooldown(window: .seconds(3), now: clock.read)

        cooldown.arm()

        XCTAssertTrue(cooldown.isActive())
    }

    func testStillActiveJustInsideTheWindow() {
        let clock = FakeClock()
        let cooldown = SelfCooldown(window: .seconds(3), now: clock.read)
        cooldown.arm()

        clock.instant = clock.instant.advanced(by: .milliseconds(2_999))

        XCTAssertTrue(cooldown.isActive())
    }

    func testInactiveOnceTheWindowHasElapsed() {
        let clock = FakeClock()
        let cooldown = SelfCooldown(window: .seconds(3), now: clock.read)
        cooldown.arm()

        clock.instant = clock.instant.advanced(by: .seconds(3))

        XCTAssertFalse(cooldown.isActive())
    }

    /// A second claim/release extends the window from that moment.
    func testReArmingRestartsTheWindow() {
        let clock = FakeClock()
        let cooldown = SelfCooldown(window: .seconds(3), now: clock.read)
        cooldown.arm()

        clock.instant = clock.instant.advanced(by: .milliseconds(2_500))
        cooldown.arm()
        clock.instant = clock.instant.advanced(by: .milliseconds(1_500))

        XCTAssertTrue(cooldown.isActive(), "re-arming should extend the window from that point")
    }

    /// #251. Was 3 seconds; ADR 0010's 2026-09-23 amendment makes it 6.
    ///
    /// The original *estimated* "~3 seconds" for thrw's own side effect
    /// to play out. ADR 0018 later *measured* a claim taking 3-5s to move
    /// the route, so the window closed before the transition it exists to
    /// cover had finished - and on hardware the tail of that transition
    /// was read as a fresh `media` trigger, bouncing the headset between
    /// devices indefinitely.
    ///
    /// `adapter-android`'s `DEFAULT_WINDOW_MS` is the same number on the
    /// other side of the same behaviour.
    func testTheDefaultWindowIsTheSixSecondsAdr0010Specifies() {
        XCTAssertEqual(defaultSelfCooldown, .seconds(6))
    }
}
