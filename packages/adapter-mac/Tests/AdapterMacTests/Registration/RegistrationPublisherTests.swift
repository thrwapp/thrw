import XCTest

@testable import AdapterMac

/// Lock-guarded so the publisher's task and the test can both touch it -
/// the same approach ``SelfCooldown`` uses.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class RegistrationPublisherTests: XCTestCase {
    /// The interval must stay long relative to the heartbeat, or every
    /// node re-announces constantly for a case that is rare.
    func testTheDefaultIntervalIsTheTwoMinutesDocumented() {
        XCTAssertEqual(defaultRegistrationInterval, .seconds(120))
        XCTAssertTrue(
            defaultRegistrationInterval > defaultHeartbeatInterval,
            "re-registration must be rarer than the heartbeat"
        )
    }

    /// `NodeRuntime` has already registered once by the time this starts,
    /// so sending immediately would be a duplicate for no benefit. This
    /// is deliberately the opposite of `HeartbeatPublisher`, which beats
    /// first and sleeps after.
    func testItSleepsBeforeTheFirstSend() async throws {
        let sent = Counter()
        let publisher = RegistrationPublisher(interval: .seconds(1), sleep: { _ in
            // Never completes: if `run` sent before sleeping, the counter
            // would already be non-zero.
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        let task = Task { try await publisher.run { sent.increment() } }
        defer { task.cancel() }

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sent.value, 0, "must not re-register before the first interval elapses")
    }

    func testItReRegistersOncePerInterval() async throws {
        let sent = Counter()
        let publisher = RegistrationPublisher(interval: .seconds(1), sleep: { _ in })
        let task = Task { try await publisher.run { sent.increment() } }
        defer { task.cancel() }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, sent.value < 3 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertGreaterThanOrEqual(sent.value, 3)
    }
}
