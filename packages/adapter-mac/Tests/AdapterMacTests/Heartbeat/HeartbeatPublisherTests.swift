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
    private var _cancelOnBeat: Int?

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

    /// #236 - distinguishes "the publish failed" from "the task was
    /// cancelled". ``HeartbeatPublisher/run()`` must swallow the first
    /// and re-throw the second, so a test needs to provoke each.
    func failCancellationOnBeat(_ beat: Int) {
        lock.lock()
        defer { lock.unlock() }
        _cancelOnBeat = beat
    }

    func publishHeartbeat() async throws {
        lock.lock()
        _beats += 1
        let shouldFail = _beats == _failOnBeat
        let shouldCancel = _beats == _cancelOnBeat
        lock.unlock()
        if shouldCancel { throw CancellationError() }
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

    /// #236. This is the reverse of the assertion it replaces, which
    /// required a failed beat to propagate out of `run()` on the grounds
    /// that "a transport that can't publish is worth surfacing, not
    /// swallowing into an invisible retry."
    ///
    /// The concern was right; the remedy was not. Propagating ends the
    /// loop, ``NodeRuntime`` logs it once, and nothing restarts it - so
    /// the node goes on registering every 120s while never beating again,
    /// which makes the relay reap it 90s after each registration and hand
    /// the headset back and forth indefinitely (nine and a half hours of
    /// it in production - see ``HeartbeatPublisher/run()``'s own kdoc).
    /// "Surfaced" is now the transition log line inside `run()`, which
    /// costs nothing and does not stop the node heartbeating.
    func testAFailedBeatDoesNotEndTheLoop() async {
        let sink = RecordingHeartbeatSink()
        sink.failOnBeat(1)
        let publisher = HeartbeatPublisher(sink: sink, interval: .seconds(30), sleep: sleepStub(afterSleeps: 5))

        do {
            try await publisher.run()
            XCTFail("expected the stub's cancellation to end the loop")
        } catch is CancellationError {
            // The only thing that should ever end this loop.
        } catch {
            XCTFail("a publish failure must not escape run(): \(error)")
        }

        // Beat 1 threw; beats 2-5 still went out. Before #236 this was 1.
        XCTAssertEqual(sink.beats, 5, "expected beating to continue after a failed beat")
    }

    /// The other half: cancellation must still escape, or nothing can
    /// stop the loop and ``NodeRuntime`` logs an error on every app quit.
    func testCancellationFromAPublishIsNotTreatedAsAFailure() async {
        let sink = RecordingHeartbeatSink()
        sink.failCancellationOnBeat(1)
        let publisher = HeartbeatPublisher(sink: sink, interval: .seconds(30), sleep: sleepStub(afterSleeps: 10))

        do {
            try await publisher.run()
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
            // Correct - re-thrown by run()'s `catch is CancellationError`.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(sink.beats, 1, "expected no beat after the cancelled one")
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
