import XCTest

@testable import AdapterMac

private final class RecordingMediaKeySender: MediaKeySender, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var presses: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func sendPlayPause() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private struct StubPlaybackState: AudioPlaybackState {
    let playing: Bool?
    func isPlaying() -> Bool? { playing }
}

private struct StubAccessibility: AccessibilityAuthorization {
    let trusted: Bool
    func isTrusted() -> Bool { trusted }
}

/// Records what a fallback gate was asked to do, so the delegation path
/// is observable.
private final class RecordingFallback: HandoverAudioGate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var suppressing = false

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func silence() async {
        lock.lock()
        defer { lock.unlock() }
        recorded.append("silence")
        suppressing = true
    }

    func restore() async {
        lock.lock()
        defer { lock.unlock() }
        recorded.append("restore")
        suppressing = false
    }

    func isSuppressing() async -> Bool { suppressing }
}

final class PausingHandoverAudioGateTests: XCTestCase {
    private func gate(
        playing: Bool?,
        trusted: Bool = true,
        fallback: HandoverAudioGate = NoOpHandoverAudioGate()
    ) -> (PausingHandoverAudioGate, RecordingMediaKeySender) {
        let key = RecordingMediaKeySender()
        return (
            PausingHandoverAudioGate(
                mediaKey: key,
                playback: StubPlaybackState(playing: playing),
                accessibility: StubAccessibility(trusted: trusted),
                fallback: fallback
            ),
            key
        )
    }

    func testAClaimPausesPlaybackAndResumesIt() async {
        let (gate, key) = gate(playing: true)

        await gate.silence()
        XCTAssertEqual(key.presses, 1, "one press to pause")

        await gate.restore()
        XCTAssertEqual(key.presses, 2, "and one to resume")
    }

    // MARK: - the toggle trap (ADR 0022's stated objection)

    /// The failure the amendment named: on the release path the gate
    /// wants "pause", and an already-paused Mac would *start playing* if
    /// the key were fired blind.
    func testNothingPlayingMeansTheKeyIsNeverPressed() async {
        let (gate, key) = gate(playing: false)

        await gate.silence()

        XCTAssertEqual(key.presses, 0, "firing the toggle here would start playback the user stopped")
    }

    /// A state that cannot be read must be treated as "do nothing",
    /// never as "probably playing" — the toggle makes a wrong guess
    /// audible in the worst possible way.
    func testAnUnreadablePlaybackStateMeansTheKeyIsNeverPressed() async {
        let (gate, key) = gate(playing: nil)

        await gate.silence()

        XCTAssertEqual(key.presses, 0)
    }

    /// `restore()` must not start audio this gate never paused. It runs
    /// on outcome paths that may never have reached a `silence()`, and
    /// on the claim after a release that paused nothing.
    func testRestoreWithoutAPauseDoesNotPressTheKey() async {
        let (gate, key) = gate(playing: true)

        await gate.restore()

        XCTAssertEqual(key.presses, 0)
    }

    /// The normal handover sequence, not an edge case: a release
    /// silences without restoring, so the next claim's `silence()` lands
    /// on a gate that is already suppressing. Pressing again would
    /// resume the audio this gate just stopped.
    func testASecondSilenceDoesNotResumeWhatTheFirstPaused() async {
        let (gate, key) = gate(playing: true)

        await gate.silence()  // release: pause, no restore
        await gate.silence()  // the claim that follows
        XCTAssertEqual(key.presses, 1, "the second silence must be a no-op")

        await gate.restore()
        XCTAssertEqual(key.presses, 2, "and the eventual restore resumes exactly once")
    }

    // MARK: - no Accessibility grant (#267 criterion 3)

    func testWithoutAccessibilityTheFallbackTakesTheWholeWindow() async {
        let fallback = RecordingFallback()
        let (gate, key) = gate(playing: true, trusted: false, fallback: fallback)

        await gate.silence()
        await gate.restore()

        XCTAssertEqual(key.presses, 0, "no grant means no synthesised events, which would be discarded anyway")
        XCTAssertEqual(fallback.calls, ["silence", "restore"])
    }

    /// Never half-act. A grant arriving mid-window must not leave the
    /// fallback's suppression to be undone by the wrong mechanism.
    func testAGrantArrivingMidWindowStillRestoresThroughTheFallback() async {
        let fallback = RecordingFallback()
        let key = RecordingMediaKeySender()
        let accessibility = MutableAccessibility(trusted: false)
        let gate = PausingHandoverAudioGate(
            mediaKey: key,
            playback: StubPlaybackState(playing: true),
            accessibility: accessibility,
            fallback: fallback
        )

        await gate.silence()
        accessibility.trusted = true
        await gate.restore()

        XCTAssertEqual(fallback.calls, ["silence", "restore"], "the mechanism that suppressed must be the one that restores")
        XCTAssertEqual(key.presses, 0)
    }

    func testWithoutAccessibilityAndWithoutAFallbackNothingHappens() async {
        let (gate, key) = gate(playing: true, trusted: false)

        await gate.silence()
        await gate.restore()

        XCTAssertEqual(key.presses, 0)
    }

    // MARK: - #265's indicator

    /// A paused player is self-evident, so it needs no menu indicator —
    /// that item exists to explain a *mute*, which has no visible cause.
    func testAPausedGateReportsNoSuppressionToTheMenu() async {
        let (gate, _) = gate(playing: true)

        await gate.silence()

        let suppressing = await gate.isSuppressing()
        XCTAssertFalse(suppressing)
    }

    /// But a delegated mute does need one, so the answer is the
    /// fallback's rather than a flat `false`.
    func testADelegatedMuteIsStillReportedToTheMenu() async {
        let fallback = RecordingFallback()
        let (gate, _) = gate(playing: true, trusted: false, fallback: fallback)

        await gate.silence()

        let suppressing = await gate.isSuppressing()
        XCTAssertTrue(suppressing)
    }
}

/// Accessibility that can be granted part-way through a test.
private final class MutableAccessibility: AccessibilityAuthorization, @unchecked Sendable {
    var trusted: Bool
    init(trusted: Bool) { self.trusted = trusted }
    func isTrusted() -> Bool { trusted }
}
