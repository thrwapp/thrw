import XCTest

@testable import AdapterMac

/// Drives ``AudioPlaybackSource`` by hand, like
/// `FakeRunningApplicationSource` does for `NSWorkspace`.
private final class FakeAudioPlaybackSource: AudioPlaybackSource, @unchecked Sendable {
    private let stream: AsyncStream<AudioPlaybackEvent>
    private let continuation: AsyncStream<AudioPlaybackEvent>.Continuation

    init() {
        var c: AsyncStream<AudioPlaybackEvent>.Continuation!
        stream = AsyncStream { c = $0 }
        continuation = c
    }

    func events() -> AsyncStream<AudioPlaybackEvent> { stream }
    func send(_ e: AudioPlaybackEvent) { continuation.yield(e) }
    func finish() { continuation.finish() }
}

@MainActor
final class MediaTriggerMonitorTests: XCTestCase {
    /// Debounce that completes immediately, so tests never wait on wall
    /// time - same injectable-sleep approach `HeartbeatPublisher` uses.
    private func instant() -> @Sendable (Duration) async throws -> Void {
        { _ in }
    }

    /// A debounce that never completes, standing in for "audio stopped
    /// before the window elapsed".
    private func never() -> @Sendable (Duration) async throws -> Void {
        { _ in try await Task.sleep(nanoseconds: 10_000_000_000) }
    }

    private func waitFor(_ what: String, _ cond: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testAudioRunningPastTheDebounceReportsMedia() async throws {
        let node = RecordingEventLifecycle()
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(source: source, node: node, sleep: instant())
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.started)
        await waitFor("the media event") { !node.emitted.isEmpty }

        XCTAssertEqual(node.emitted.map(\.type), [.media])
    }

    /// The whole point of the debounce: a notification chime must not
    /// take the headset off another device.
    func testAShortBlipOfAudioNeverReportsMedia() async throws {
        let node = RecordingEventLifecycle()
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(source: source, node: node, sleep: never())
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.started)
        source.send(.stopped)
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(node.emitted.isEmpty, "a blip shorter than the debounce must not trigger")
        XCTAssertTrue(node.ended.isEmpty, "and must not report an end for a trigger that never started")
    }

    func testAudioStoppingAfterMediaWasReportedEndsIt() async throws {
        let node = RecordingEventLifecycle()
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(source: source, node: node, sleep: instant())
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.started)
        await waitFor("the media event") { !node.emitted.isEmpty }
        source.send(.stopped)
        await waitFor("the media end") { !node.ended.isEmpty }

        XCTAssertEqual(node.ended, [.media])
    }

    /// #298, the regression this exists for. The trigger reads the
    /// **default output device**, and that device changes whenever thrw
    /// attaches or detaches the headset — so a handover produces a
    /// short gap in the very signal used to decide whether to hand over.
    /// Measured on the reference Mac with YouTube playing continuously:
    /// the holder bounced between devices every ten seconds.
    ///
    /// The start debounce is `instant` and the stop debounce `never`, so
    /// the only way the end could be reported is if the blip were
    /// treated as a stop — which is precisely the bug.
    func testAShortSilenceFromADeviceChangeDoesNotEndMedia() async throws {
        let node = RecordingEventLifecycle()
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(
            source: source,
            node: node,
            debounce: .zero,
            stopDebounce: .seconds(10),
            sleep: { duration in
                // Start window elapses at once; the stop window does not.
                if duration != .zero { try await Task.sleep(nanoseconds: 10_000_000_000) }
            }
        )
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.started)
        await waitFor("the media event") { !node.emitted.isEmpty }

        // The device change: silent for a moment, then playing again.
        source.send(.stopped)
        source.send(.started)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(node.ended.isEmpty, "a device change is not the user stopping their music")
    }

    /// CoreAudio can report the same state more than once, and a rebind
    /// to a new default device re-reads it.
    func testRepeatedStartedEventsDoNotDoubleReport() async throws {
        let node = RecordingEventLifecycle()
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(source: source, node: node, sleep: instant())
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.started)
        await waitFor("the media event") { !node.emitted.isEmpty }
        source.send(.started)
        source.send(.started)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(node.emitted.count, 1)
    }

    func testStoppedWithoutAnyMediaReportsNothing() async throws {
        let node = RecordingEventLifecycle()
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(source: source, node: node, sleep: instant())
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.stopped)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(node.emitted.isEmpty)
        XCTAssertTrue(node.ended.isEmpty)
    }

    func testTheDefaultDebounceIsTheTwoSecondsDocumented() {
        XCTAssertEqual(defaultMediaDebounce, .seconds(2))
    }
}
