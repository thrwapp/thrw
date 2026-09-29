import XCTest

@testable import AdapterMac

/// #309 / scenarios.md R3. Before this, a command that failed reached
/// `logAdapterError` and stopped there, so a claim the user made and a
/// claim that silently never happened looked identical in the menu.
final class LastCommandFailureTests: XCTestCase {
    private func failure(
        type: CommandType = .claim,
        outcome: CommandOutcome = .failed,
        reason: CommandFailureReason? = nil
    ) -> CommandFailure {
        CommandFailure(type: type, outcome: outcome, reason: reason)
    }

    func testStartsWithNothingToReport() {
        XCTAssertNil(LastCommandFailure().current())
    }

    func testRecordsTheMostRecentFailure() {
        let store = LastCommandFailure()
        store.record(failure(reason: .targetDeviceUnreachable))
        XCTAssertEqual(store.current()?.reason, .targetDeviceUnreachable)
    }

    /// The point of clearing on success rather than on a timer: a notice
    /// that expired on a clock would claim things are fine while they are
    /// still broken.
    func testASuccessClearsIt() {
        let store = LastCommandFailure()
        store.record(failure())
        store.clear()
        XCTAssertNil(store.current())
    }

    func testALaterFailureReplacesAnEarlierOne() {
        let store = LastCommandFailure()
        store.record(failure(reason: .bluetoothUnavailable))
        store.record(failure(outcome: .timedOut))
        XCTAssertEqual(store.current()?.outcome, .timedOut)
    }

    /// Written from the command loop, read from the main actor when a
    /// menu opens - so it has an `NSLock`, like ``ActiveEventSet``. This
    /// asserts it survives that, rather than asserting a specific
    /// interleaving.
    func testConcurrentRecordsAndReadsDoNotCrash() {
        let store = LastCommandFailure()
        let done = expectation(description: "concurrent access")
        done.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            for _ in 0..<500 { store.record(self.failure()) }
            done.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<500 { _ = store.current() }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
