import XCTest

@testable import AdapterMac

private let deviceIdentifier = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
private let otherDeviceIdentifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

final class BluetoothConnectionManagerTests: XCTestCase {
    func testUnknownDeviceReportsDisconnected() async {
        let manager = BluetoothConnectionManager(gateway: FakeBluetoothPeripheralGateway())

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected)
    }

    func testConnectTransitionsToConnectedAndCallsTheGatewayOnce() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)

        try await manager.connect(deviceIdentifier: deviceIdentifier)

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(gateway.connectCalls, [deviceIdentifier])
    }

    func testConnectWhileAlreadyConnectedIsANoOp() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)

        try await manager.connect(deviceIdentifier: deviceIdentifier)
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(gateway.connectCalls, [deviceIdentifier])
    }

    func testFailedConnectRevertsToDisconnectedAndPropagatesTheError() async {
        let gateway = FakeBluetoothPeripheralGateway()
        gateway.failNextConnect = true
        let manager = BluetoothConnectionManager(gateway: gateway)

        do {
            try await manager.connect(deviceIdentifier: deviceIdentifier)
            XCTFail("expected connect to throw")
        } catch is FakeGatewayError {
            // expected
        } catch {
            XCTFail("expected FakeGatewayError, got \(error)")
        }

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected)
    }

    func testConnectAfterAFailedAttemptIsRetried() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        gateway.failNextConnect = true
        let manager = BluetoothConnectionManager(gateway: gateway)

        do {
            try await manager.connect(deviceIdentifier: deviceIdentifier)
            XCTFail("expected first connect to throw")
        } catch {
            // expected
        }
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(gateway.connectCalls, [deviceIdentifier, deviceIdentifier])
    }

    func testDisconnectTransitionsAConnectedDeviceBackToDisconnected() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        try await manager.disconnect(deviceIdentifier: deviceIdentifier)

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected)
        XCTAssertEqual(gateway.disconnectCalls, [deviceIdentifier])
    }

    func testDisconnectingAnUnknownDeviceIsANoOpThatNeverCallsTheGateway() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)

        try await manager.disconnect(deviceIdentifier: deviceIdentifier)

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected)
        XCTAssertTrue(gateway.disconnectCalls.isEmpty)
    }

    func testDisconnectingAnAlreadyDisconnectedDeviceDoesNotCallTheGatewayAgain() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)
        try await manager.connect(deviceIdentifier: deviceIdentifier)
        try await manager.disconnect(deviceIdentifier: deviceIdentifier)

        try await manager.disconnect(deviceIdentifier: deviceIdentifier)

        XCTAssertEqual(gateway.disconnectCalls, [deviceIdentifier])
    }

    func testEvenAFailedDisconnectLeavesStateDisconnected() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)
        try await manager.connect(deviceIdentifier: deviceIdentifier)
        gateway.failNextDisconnect = true

        do {
            try await manager.disconnect(deviceIdentifier: deviceIdentifier)
            XCTFail("expected disconnect to throw")
        } catch {
            // expected
        }

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected)
    }

    func testEachDeviceIdentifierIsTrackedIndependently() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)

        try await manager.connect(deviceIdentifier: deviceIdentifier)

        let trackedState = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        let otherState = await manager.connectionState(deviceIdentifier: otherDeviceIdentifier)
        XCTAssertEqual(trackedState, .connected)
        XCTAssertEqual(otherState, .disconnected)
    }
}

/// A ``DeviceAudioRouteSource`` whose answer the test sets directly.
private final class StubRouteSource: DeviceAudioRouteSource, @unchecked Sendable {
    var answer: Bool?
    private(set) var askedAbout: [UUID] = []

    init(_ answer: Bool?) {
        self.answer = answer
    }

    func holdsAudioRoute(deviceIdentifier: UUID) -> Bool? {
        askedAbout.append(deviceIdentifier)
        return answer
    }
}

/// #225 / ADR 0018 decision 3. Android has done this since #191; macOS
/// did not, and the ADR says getting it wrong here is worse than getting
/// decision 2 wrong — the claim is skipped silently, with no log, no
/// retry and no audio.
final class BluetoothConnectionManagerRouteTests: XCTestCase {
    /// The measured multipoint state on the reference hardware: the Mac
    /// still holds its Bluetooth link to the AirPods (so `states` says
    /// `.connected`) while the phone holds the route and the Mac's
    /// output is its own speakers. A claim arriving now is genuinely
    /// needed.
    func testAClaimIsExecutedWhenTheCacheSaysConnectedButTheRouteHasGone() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway, routeSource: StubRouteSource(false))

        try await manager.connect(deviceIdentifier: deviceIdentifier)
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        XCTAssertEqual(
            gateway.connectCalls,
            [deviceIdentifier, deviceIdentifier],
            "the second claim must not be skipped on a cache multipoint has invalidated"
        )
        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .connected)
    }

    func testAClaimIsStillSkippedWhenTheRouteConfirmsTheCache() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway, routeSource: StubRouteSource(true))

        try await manager.connect(deviceIdentifier: deviceIdentifier)
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        XCTAssertEqual(gateway.connectCalls, [deviceIdentifier])
    }

    /// `nil` is "cannot tell", and must not be smoothed into `false`.
    /// Overriding a cached state on the strength of a reading that does
    /// not exist would issue a redundant disconnect/reconnect cycle
    /// every time CoreAudio was momentarily unreadable.
    func testAnUnreadableRouteLeavesTheCachedSkipAlone() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway, routeSource: StubRouteSource(nil))

        try await manager.connect(deviceIdentifier: deviceIdentifier)
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        XCTAssertEqual(gateway.connectCalls, [deviceIdentifier])
    }

    /// A node built without a route source behaves exactly as it did
    /// before #225 — criterion 3. The observer is optional on this
    /// platform (`AppDelegate` logs and continues when the headset
    /// address is missing), so this is a real configuration.
    func testWithoutARouteSourceTheCachedSkipIsUnchanged() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(gateway: gateway)

        try await manager.connect(deviceIdentifier: deviceIdentifier)
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        XCTAssertEqual(gateway.connectCalls, [deviceIdentifier])
    }

    /// Only `.connected` is second-guessed. `.connecting` means a claim
    /// is already in flight, and re-entering would issue a duplicate —
    /// so the route is not even consulted.
    func testAnInFlightConnectIsNotSecondGuessed() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        gateway.blockNextConnect = true
        let routeSource = StubRouteSource(false)
        let manager = BluetoothConnectionManager(gateway: gateway, routeSource: routeSource)

        let inFlight = Task { try await manager.connect(deviceIdentifier: deviceIdentifier) }
        await gateway.waitUntilConnectStarted()

        try await manager.connect(deviceIdentifier: deviceIdentifier)

        XCTAssertEqual(gateway.connectCalls, [deviceIdentifier], "a duplicate connect must not be issued")
        XCTAssertTrue(routeSource.askedAbout.isEmpty, "the route is not consulted while connecting")
        gateway.releaseBlockedConnect()
        try await inFlight.value
    }

    /// A fresh device is connected without consulting the route at all —
    /// there is no cached belief to second-guess.
    func testAFirstConnectDoesNotConsultTheRoute() async throws {
        let routeSource = StubRouteSource(true)
        let manager = BluetoothConnectionManager(
            gateway: FakeBluetoothPeripheralGateway(), routeSource: routeSource
        )

        try await manager.connect(deviceIdentifier: deviceIdentifier)

        XCTAssertTrue(routeSource.askedAbout.isEmpty)
    }
}

/// The identity guard in ``HeadsetAudioRouteSource``. A node manages one
/// headset today, so this never fires in production — but an observer
/// bound to the AirPods answering confidently about a different paired
/// device would be a fabricated answer, and the failure it produces is a
/// silently skipped claim.
final class HeadsetAudioRouteSourceTests: XCTestCase {
    private struct StubObserver: AudioRouteObserver {
        let holds: Bool?
        func holdsAudioRoute() -> Bool? { holds }
    }

    func testAnswersForItsOwnHeadset() {
        let source = HeadsetAudioRouteSource(
            headsetIdentifier: deviceIdentifier, observer: StubObserver(holds: false)
        )

        XCTAssertEqual(source.holdsAudioRoute(deviceIdentifier: deviceIdentifier), false)
    }

    func testReportsNoInformationForAnyOtherDevice() {
        let source = HeadsetAudioRouteSource(
            headsetIdentifier: deviceIdentifier, observer: StubObserver(holds: false)
        )

        XCTAssertNil(
            source.holdsAudioRoute(deviceIdentifier: otherDeviceIdentifier),
            "a false here would assert something this observer cannot know"
        )
    }

    func testPassesThroughAnUnreadableRoute() {
        let source = HeadsetAudioRouteSource(
            headsetIdentifier: deviceIdentifier, observer: StubObserver(holds: nil)
        )

        XCTAssertNil(source.holdsAudioRoute(deviceIdentifier: deviceIdentifier))
    }
}
