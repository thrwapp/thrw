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

/// #303. Swallows the first `endsToSwallow` calls to `endEvent` exactly
/// the way ``MacNode`` does while a route transition is executing: it
/// returns without publishing **and without clearing the trigger**, so
/// the node goes on reporting it.
///
/// That is the state the reference Mac was stuck in for seventeen
/// minutes - `activeEvents: ["media"]` on every registration with
/// CoreAudio reporting nothing playing - because the monitor had already
/// forgotten the trigger and nothing retried.
private final class SwallowingEventLifecycle: EventLifecycle, @unchecked Sendable {
    private let lock = NSLock()
    private var active: [EventKind] = []
    private var swallowsLeft: Int
    private var endAttempts = 0

    init(endsToSwallow: Int) {
        swallowsLeft = endsToSwallow
    }

    var attemptedEnds: Int {
        lock.lock()
        defer { lock.unlock() }
        return endAttempts
    }

    func emitEvent(type: EventKind, priority: Priority) async throws {
        lock.lock()
        if !active.contains(type) { active.append(type) }
        lock.unlock()
    }

    func endEvent(type: EventKind) async throws {
        lock.lock()
        endAttempts += 1
        if swallowsLeft > 0 {
            swallowsLeft -= 1
            lock.unlock()
            return
        }
        active.removeAll { $0 == type }
        lock.unlock()
    }

    func isEventActive(_ type: EventKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.contains(type)
    }

    func activeEventKinds() -> [EventKind] {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
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

    // MARK: - an end the node swallows mid-transition (#303)

    /// The phantom `media` event, and the retry that ends it.
    ///
    /// `MacNode.endEvent` returns without touching anything while a route
    /// transition is executing (#295, so the audio gate's own pause
    /// leaves no trace on this node's triggers). This monitor had already
    /// cleared `reportedMedia` by then, so the end was lost with nothing
    /// to retry it: the node kept reporting `media` as active, the relay
    /// kept a node that could not hold the route as its holder, and only
    /// quitting the app cleared it.
    func testAnEndSwallowedMidTransitionIsRetriedUntilItLands() async throws {
        let node = SwallowingEventLifecycle(endsToSwallow: 1)
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(source: source, node: node, sleep: instant())
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.started)
        await waitFor("the media event") { node.isEventActive(.media) }

        source.send(.stopped)
        await waitFor("the retried end to land") { !node.isEventActive(.media) }

        XCTAssertEqual(node.attemptedEnds, 2, "the first end was swallowed, so exactly one retry was needed")
    }

    /// The property that matters, stated on its own: the trigger does not
    /// survive the transition that swallowed its end. Without the retry
    /// this stays active forever.
    func testMediaDoesNotStayActiveAfterASwallowedEnd() async throws {
        let node = SwallowingEventLifecycle(endsToSwallow: 3)
        let source = FakeAudioPlaybackSource()
        let monitor = MediaTriggerMonitor(source: source, node: node, sleep: instant())
        let task = Task { try await monitor.run() }
        defer { task.cancel() }

        source.send(.started)
        await waitFor("the media event") { node.isEventActive(.media) }
        source.send(.stopped)

        await waitFor("media to stop being active") { !node.isEventActive(.media) }
        XCTAssertEqual(node.attemptedEnds, 4)
    }

}
