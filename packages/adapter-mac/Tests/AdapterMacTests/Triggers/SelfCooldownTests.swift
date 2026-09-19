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

    func testTheDefaultWindowIsTheThreeSecondsAdr0010Specifies() {
        XCTAssertEqual(defaultSelfCooldown, .seconds(3))
    }
}
