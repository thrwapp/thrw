import XCTest

@testable import AdapterMac

/// Records beats and can end the loop on demand, so a test never waits
/// on wall time - same fake-at-the-seam discipline as
/// `FakeMqttTransport`/`FakeRunningApplicationSource`.
///
/// Lock-guarded, unlike this package's other fakes: those are driven
/// sequentially inside one `async` test, but ``HeartbeatPublisher/run()``
/// is deliberately exercised here from a real background `Task` while the
/// test thread reads `beats`. An unguarded `Int` across those two is a
/// genuine data race - it crashed the test binary at teardown (signal 11)
/// before this lock existed, which is exactly what `@unchecked Sendable`
/// stops the compiler telling you.
private final class RecordingHeartbeatSink: HeartbeatSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _beats = 0
    private var _failOnBeat: Int?

    struct Boom: Error {}

    var beats: Int {
        lock.lock()
        defer { lock.unlock() }
        return _beats
    }

    func failOnBeat(_ beat: Int) {
        lock.lock()
        defer { lock.unlock() }
        _failOnBeat = beat
    }

    func publishHeartbeat() async throws {
        lock.lock()
        _beats += 1
        let shouldFail = _beats == _failOnBeat
        lock.unlock()
        if shouldFail { throw Boom() }
    }
}

final class HeartbeatPublisherTests: XCTestCase {
    /// Ends `run()`'s infinite loop after `afterSleeps` sleeps, by
    /// cancelling rather than by throwing something unexpected.
    private func sleepStub(
        afterSleeps: Int,
        recorded: @escaping @Sendable (Duration) -> Void = { _ in }
    ) -> @Sendable (Duration) async throws -> Void {
        let count = Counter()
        return { duration in
            recorded(duration)
            if await count.increment() >= afterSleeps { throw CancellationError() }
        }
    }

    private actor Counter {
        private var value = 0
        func increment() -> Int {
            value += 1
            return value
        }
    }

    func testBeatsImmediatelyWithoutWaitingOutTheFirstInterval() async throws {
        let sink = RecordingHeartbeatSink()
        let publisher = HeartbeatPublisher(sink: sink, interval: .seconds(30), sleep: sleepStub(afterSleeps: 1))

        try? await publisher.run()

        // One beat before the first sleep - the relay stamps liveness at
        // registration, so waiting 30s for beat one would burn a third
        // of its 90s budget doing nothing.
        XCTAssertEqual(sink.beats, 1)
    }

    func testKeepsBeatingOncePerInterval() async throws {
        let sink = RecordingHeartbeatSink()
        let publisher = HeartbeatPublisher(sink: sink, interval: .seconds(30), sleep: sleepStub(afterSleeps: 5))

        try? await publisher.run()

        XCTAssertEqual(sink.beats, 5)
    }

    func testSleepsForTheConfiguredInterval() async throws {
        let sink = RecordingHeartbeatSink()
        let observed = DurationBox()
        let publisher = HeartbeatPublisher(
            sink: sink,
            interval: .seconds(7),
            sleep: sleepStub(afterSleeps: 1, recorded: { observed.value = $0 })
        )

        try? await publisher.run()

        XCTAssertEqual(observed.value, .seconds(7))
    }

    func testTheDefaultIntervalIsTheThirtySecondsArchitectureMdSpecifies() {
        // architecture.md's topic table: `heartbeat  QoS 0, ~30s`, and
        // relay-hosted's 90s timeout is 3x this. If this assertion is
        // ever "fixed" by changing the constant, change the relay's
        // timeout in the same PR - see HeartbeatPublisher's own kdoc.
        XCTAssertEqual(defaultHeartbeatInterval, .seconds(30))
    }

    func testAFailedBeatPropagatesRatherThanSpinningSilently() async {
        let sink = RecordingHeartbeatSink()
        sink.failOnBeat(1)
        let publisher = HeartbeatPublisher(sink: sink, interval: .seconds(30), sleep: sleepStub(afterSleeps: 10))

        do {
            try await publisher.run()
            XCTFail("expected the publish failure to propagate")
        } catch is RecordingHeartbeatSink.Boom {
            // NodeRuntime logs this - a transport that can't publish is
            // worth surfacing, not swallowing into an invisible retry.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStopsBeatingOnceTheTaskIsCancelled() async throws {
        let sink = RecordingHeartbeatSink()
        // Never ends on its own - only cancellation stops this one.
        let publisher = HeartbeatPublisher(sink: sink, interval: .milliseconds(1))

        let task = Task { try await publisher.run() }
        // Let it get at least one beat out before cancelling, without
        // busy-spinning on a value another task is writing.
        while sink.beats == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        _ = await task.result

        let beatsAtCancel = sink.beats
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sink.beats, beatsAtCancel, "expected no further beats after cancellation")
    }
}

/// Minimal box so the `@Sendable` sleep closure can hand a value back out.
private final class DurationBox: @unchecked Sendable {
    var value: Duration = .zero
}
