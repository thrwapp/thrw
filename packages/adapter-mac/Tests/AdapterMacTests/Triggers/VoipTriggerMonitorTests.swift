import XCTest

@testable import AdapterMac

private let zoom = RunningApplicationInfo(bundleIdentifier: "us.zoom.xos")
private let faceTime = RunningApplicationInfo(bundleIdentifier: "com.apple.FaceTime")
private let unrelatedApp = RunningApplicationInfo(bundleIdentifier: "com.example.NotVoip")

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
