import XCTest

@testable import AdapterMac

private let zoom = RunningApplicationInfo(bundleIdentifier: "us.zoom.xos")
private let faceTime = RunningApplicationInfo(bundleIdentifier: "com.apple.FaceTime")
private let unrelatedApp = RunningApplicationInfo(bundleIdentifier: "com.example.NotVoip")

/// #247. Supplies a microphone source so the two-input path is active;
/// the value is driven directly through `handleMicrophone` rather than
/// through the stream, so both orderings can be exercised.
private struct StubMicrophone: MicrophoneActivitySource {
    func activity() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

/// #247 - a known VoIP app being *open* is not a call.
///
/// Leaving Slack or WhatsApp running used to pin the headset to this Mac
/// indefinitely: `voip` outranks `media` in `PRIORITY_ORDER`, so
/// deliberate playback on the phone could never win it back. Reproduced
/// on the reference pair before this landed.
final class VoipTriggerMonitorMicrophoneTests: XCTestCase {
    private func monitor(_ node: RecordingEventLifecycle) -> VoipTriggerMonitor {
        VoipTriggerMonitor(
            source: FakeRunningApplicationSource(),
            node: node,
            microphone: StubMicrophone()
        )
    }

    func testAVoipAppOpenWithNoMicrophoneDoesNotEmit() async throws {
        let node = RecordingEventLifecycle()
        let m = monitor(node)

        try await m.handle(.launched(zoom))

        XCTAssertEqual(node.emitted, [], "an open app is not a call - this is the whole of #247")
    }

    func testTheMicrophoneAloneDoesNotEmit() async throws {
        // Voice Memos, a screen recording, a browser call in a tab we
        // cannot see - the mic being live is not evidence of a VoIP
        // session by itself. Both conditions, or neither.
        let node = RecordingEventLifecycle()
        let m = monitor(node)

        try await m.handleMicrophone(true)

        XCTAssertEqual(node.emitted, [])
    }

    func testAVoipAppPlusTheMicrophoneEmits() async throws {
        let node = RecordingEventLifecycle()
        let m = monitor(node)

        try await m.handle(.launched(zoom))
        try await m.handleMicrophone(true)

        XCTAssertEqual(node.emitted, [.init(type: .voip, priority: unrankedPriority)])
    }

    /// Order matters: a call can start in an app open for hours, or an
    /// app can launch while the mic is already live.
    func testTheOppositeOrderAlsoEmits() async throws {
        let node = RecordingEventLifecycle()
        let m = monitor(node)

        try await m.handleMicrophone(true)
        try await m.handle(.launched(zoom))

        XCTAssertEqual(node.emitted, [.init(type: .voip, priority: unrankedPriority)])
    }

    func testTheCallEndingEndsVoipEvenThoughTheAppIsStillOpen() async throws {
        // The case that was impossible before: hanging up without
        // quitting the app. Previously the trigger stayed active until
        // the app terminated, which for Slack might be never.
        let node = RecordingEventLifecycle()
        let m = monitor(node)

        try await m.handle(.launched(zoom))
        try await m.handleMicrophone(true)
        try await m.handleMicrophone(false)

        XCTAssertEqual(node.ended, [.voip])
    }

    func testQuittingTheAppMidCallAlsoEndsVoip() async throws {
        let node = RecordingEventLifecycle()
        let m = monitor(node)

        try await m.handle(.launched(zoom))
        try await m.handleMicrophone(true)
        try await m.handle(.terminated(zoom))

        XCTAssertEqual(node.ended, [.voip])
    }

    func testRepeatedMicrophoneChangesDoNotDoubleEmit() async throws {
        // CoreAudio fires its listener for several reasons. The real
        // source filters unchanged values, but the monitor must not
        // depend on that to stay correctly paired.
        let node = RecordingEventLifecycle()
        let m = monitor(node)

        try await m.handle(.launched(zoom))
        try await m.handleMicrophone(true)
        try await m.handleMicrophone(true)

        XCTAssertEqual(node.emitted.count, 1)
        XCTAssertEqual(node.ended, [])
    }

    /// Without a microphone source the monitor keeps its old behaviour.
    /// Silently never reporting VoIP would be a worse failure than
    /// over-reporting it, so the degradation is deliberate.
    func testWithoutAMicrophoneSourceTheOldBehaviourIsUnchanged() async throws {
        let node = RecordingEventLifecycle()
        let m = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)

        try await m.handle(.launched(zoom))

        XCTAssertEqual(node.emitted, [.init(type: .voip, priority: unrankedPriority)])
    }
}

final class VoipTriggerMonitorTests: XCTestCase {
    func testLaunchingAKnownVoipAppEmitsVoip() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)

        try await monitor.handle(.launched(zoom))

        XCTAssertEqual(node.emitted, [.init(type: .voip, priority: unrankedPriority)])
    }

    func testLaunchingAnUnknownAppIsIgnored() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)

        try await monitor.handle(.launched(unrelatedApp))

        XCTAssertTrue(node.emitted.isEmpty)
    }

    func testLaunchingTheSameVoipAppTwiceDoesNotDoubleEmit() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)

        try await monitor.handle(.launched(zoom))
        try await monitor.handle(.launched(zoom))

        XCTAssertEqual(node.emitted.count, 1)
    }

    func testASecondConcurrentVoipAppDoesNotEmitASecondStart() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)

        try await monitor.handle(.launched(zoom))
        try await monitor.handle(.launched(faceTime))

        XCTAssertEqual(node.emitted.count, 1)
    }

    func testTerminatingTheLastActiveVoipAppEndsVoip() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)
        try await monitor.handle(.launched(zoom))

        try await monitor.handle(.terminated(zoom))

        XCTAssertEqual(node.ended, [.voip])
    }

    func testTerminatingOneOfTwoConcurrentVoipAppsDoesNotEndVoip() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)
        try await monitor.handle(.launched(zoom))
        try await monitor.handle(.launched(faceTime))

        try await monitor.handle(.terminated(zoom))

        XCTAssertTrue(node.ended.isEmpty)

        try await monitor.handle(.terminated(faceTime))
        XCTAssertEqual(node.ended, [.voip])
    }

    func testTerminatingAnAppThatWasNeverTrackedIsANoOp() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(source: FakeRunningApplicationSource(), node: node)

        try await monitor.handle(.terminated(zoom))

        XCTAssertTrue(node.ended.isEmpty)
    }

    func testACustomBundleIdentifierSetReplacesTheDefault() async throws {
        let node = RecordingEventLifecycle()
        let monitor = VoipTriggerMonitor(
            source: FakeRunningApplicationSource(),
            node: node,
            voipBundleIdentifiers: ["com.example.CustomVoip"]
        )

        try await monitor.handle(.launched(zoom))
        XCTAssertTrue(node.emitted.isEmpty, "zoom is not in the custom set, so it should be ignored")

        try await monitor.handle(.launched(RunningApplicationInfo(bundleIdentifier: "com.example.CustomVoip")))
        XCTAssertEqual(node.emitted.count, 1)
    }

    func testRunCollectsEventsFromTheSourceUntilItFinishes() async throws {
        let node = RecordingEventLifecycle()
        let source = FakeRunningApplicationSource()
        let monitor = VoipTriggerMonitor(source: source, node: node)

        source.send(.launched(zoom))
        source.send(.terminated(zoom))
        source.finish()

        try await monitor.run()

        XCTAssertEqual(node.emitted, [.init(type: .voip, priority: unrankedPriority)])
        XCTAssertEqual(node.ended, [.voip])
    }
}
