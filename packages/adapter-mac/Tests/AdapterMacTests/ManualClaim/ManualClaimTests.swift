import XCTest

@testable import AdapterMac

/// Fails every publish, to check the local state does not drift from what
/// the relay was actually told.
private final class FailingEventLifecycle: EventLifecycle, @unchecked Sendable {
    struct Boom: Error {}
    func emitEvent(type: EventKind, priority: Priority) async throws { throw Boom() }
    func endEvent(type: EventKind) async throws { throw Boom() }
    /// Nothing ever succeeded, so nothing is ever active - which is the
    /// whole point of the test below.
    func isEventActive(_ type: EventKind) -> Bool { false }
    func activeEventKinds() -> [EventKind] { [] }
}

final class ManualClaimTests: XCTestCase {
    func testTogglingOnEmitsAManualClaim() async throws {
        let node = RecordingEventLifecycle()
        let claim = ManualClaim(node: node)

        let held = try await claim.toggle()

        XCTAssertTrue(held)
        XCTAssertEqual(node.emitted.map(\.type), [.manualClaim])
        XCTAssertTrue(node.ended.isEmpty, "claiming must not also end it - see the kdoc")
    }

    func testTogglingOffEndsIt() async throws {
        let node = RecordingEventLifecycle()
        let claim = ManualClaim(node: node)

        _ = try await claim.toggle()
        let held = try await claim.toggle()

        XCTAssertFalse(held)
        XCTAssertEqual(node.ended, [.manualClaim])
    }

    /// The claim has to persist, or the engine recomputes the holder from
    /// whatever is still active elsewhere and undoes the user's action.
    func testTheClaimIsNotEndedImmediatelyAfterBeingMade() async throws {
        let node = RecordingEventLifecycle()
        let claim = ManualClaim(node: node)

        _ = try await claim.toggle()

        XCTAssertTrue(claim.isHeld())
        XCTAssertTrue(node.ended.isEmpty)
    }

    /// If the relay could not be told, the menu must not start claiming
    /// the headset is held - the next tap should retry, not toggle into a
    /// state that only exists locally.
    func testAFailedPublishLeavesTheStateUnchanged() async {
        let claim = ManualClaim(node: FailingEventLifecycle())

        do {
            _ = try await claim.toggle()
            XCTFail("expected the publish failure to propagate")
        } catch {
            XCTAssertFalse(claim.isHeld(), "a failed claim must not be recorded as held")
        }
    }
}
