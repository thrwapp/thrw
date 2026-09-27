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

    // MARK: - a gateway call that never resolves *and* ignores cancellation (#303)

    /// #303's mechanism, in a unit test.
    ///
    /// The bound above is enforced by ``withBluetoothTimeout``, which was
    /// a `withThrowingTaskGroup` racing the work against a sleep. A task
    /// group is guaranteed empty when it returns, so it awaits every
    /// child - including one stuck in a suspension that ignores
    /// cancellation. The timeout error was produced on schedule and then
    /// queued behind the very thing it existed to escape.
    ///
    /// #244's own test could not see that, because its fake blocks on an
    /// `AsyncStream` and `cancelAll()` unsticks it. This one blocks the
    /// way `IOBluetooth` does.
    ///
    /// Run through ``callWithDeadline`` so that a bound which cannot fire
    /// **fails** this test rather than hanging the whole suite.
    func testAConnectThatIgnoresCancellationStillTimesOut() async {
        let gateway = FakeBluetoothPeripheralGateway()
        gateway.blockNextConnectUncancellably = true
        let manager = BluetoothConnectionManager(
            gateway: gateway,
            operationTimeout: .milliseconds(50)
        )

        let result = await callWithDeadline {
            try await manager.connect(deviceIdentifier: deviceIdentifier)
        }

        switch result {
        case .didNotFinish:
            XCTFail("the bound never fired - this is #303: the claim hangs with no outcome at all")
        case .finished(let error as BluetoothOperationTimedOut):
            XCTAssertEqual(error.operation, "connect")
        case .finished(let other):
            XCTFail("expected a timeout, got \(String(describing: other))")
        }

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected, "the state must resolve even though the work never will")
    }

    /// The consequence that made #303 a wedge rather than a slow switch:
    /// with the state resolved, a later claim is attempted. The abandoned
    /// task is still hung in the gateway, and that is fine - it holds
    /// nothing this manager needs.
    func testAClaimAfterAConnectThatIgnoresCancellationIsStillAttempted() async {
        let gateway = FakeBluetoothPeripheralGateway()
        gateway.blockNextConnectUncancellably = true
        let manager = BluetoothConnectionManager(
            gateway: gateway,
            operationTimeout: .milliseconds(50)
        )

        _ = await callWithDeadline { try await manager.connect(deviceIdentifier: deviceIdentifier) }
        let second = await callWithDeadline { try await manager.connect(deviceIdentifier: deviceIdentifier) }

        if case .didNotFinish = second {
            XCTFail("the second claim did not finish")
        }
        XCTAssertEqual(
            gateway.connectCalls,
            [deviceIdentifier, deviceIdentifier],
            "a claim after an unkillable one must not be skipped"
        )
    }

    /// The release side, which was not bounded at all before #303.
    ///
    /// `disconnect` promised "state always ends at `.disconnected`" via a
    /// `defer` - true only if the frame unwinds, which an unbounded
    /// `await` on a stuck gateway prevents. Left at `.disconnecting`,
    /// every later release for that device is a silent no-op, and ADR
    /// 0002's sequential handoff means the claim queued behind it never
    /// happens either.
    func testADisconnectThatIgnoresCancellationTimesOutAndResolvesTheState() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(
            gateway: gateway,
            operationTimeout: .milliseconds(50)
        )
        try await manager.connect(deviceIdentifier: deviceIdentifier)
        gateway.blockNextDisconnectUncancellably = true

        let result = await callWithDeadline {
            try await manager.disconnect(deviceIdentifier: deviceIdentifier)
        }

        switch result {
        case .didNotFinish:
            XCTFail("the release hung with no bound - this is #303 on the release path")
        case .finished(let error as BluetoothOperationTimedOut):
            XCTAssertEqual(error.operation, "disconnect")
        case .finished(let other):
            XCTFail("expected a timeout, got \(String(describing: other))")
        }

        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected)
    }

    /// And the release after it is attempted rather than skipped.
    func testAReleaseAfterOneThatIgnoredCancellationIsStillAttempted() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        let manager = BluetoothConnectionManager(
            gateway: gateway,
            operationTimeout: .milliseconds(50)
        )
        try await manager.connect(deviceIdentifier: deviceIdentifier)
        gateway.blockNextDisconnectUncancellably = true
        _ = await callWithDeadline { try await manager.disconnect(deviceIdentifier: deviceIdentifier) }

        try await manager.connect(deviceIdentifier: deviceIdentifier)
        _ = await callWithDeadline { try await manager.disconnect(deviceIdentifier: deviceIdentifier) }

        XCTAssertEqual(gateway.disconnectCalls, [deviceIdentifier, deviceIdentifier])
    }

    // MARK: - the deadline harness for the tests above

    private enum BoundedCall {
        case finished(Error?)
        case didNotFinish
    }

    /// Runs `operation` on its own task and reports how it ended, giving
    /// up after `deadline`.
    ///
    /// Deliberately does **not** await the task: the whole subject of
    /// these tests is work that cannot be cancelled or awaited out of, so
    /// awaiting it would hang the suite instead of failing a test. The
    /// abandoned task is left running; the test process outlives it by
    /// seconds.
    private func callWithDeadline(
        _ deadline: Duration = .seconds(3),
        _ operation: @escaping @Sendable () async throws -> Void
    ) async -> BoundedCall {
        let box = OutcomeBox()
        let work = Task {
            do {
                try await operation()
                box.finish(nil)
            } catch {
                box.finish(error)
            }
        }
        defer { work.cancel() }

        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if let outcome = box.outcome { return .finished(outcome.error) }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return .didNotFinish
    }

    private final class OutcomeBox: @unchecked Sendable {
        struct Outcome { let error: Error? }

        private let lock = NSLock()
        private var stored: Outcome?

        var outcome: Outcome? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func finish(_ error: Error?) {
            lock.lock()
            if stored == nil { stored = Outcome(error: error) }
            lock.unlock()
        }
    }

    // MARK: - a connect that never resolves (#244)

    /// #244, reproduced. A `gateway.connect` that never returns used to
    /// leave `states` at `.connecting` with neither the success nor the
    /// `catch` path running - and the `.connecting` branch returns early
    /// *without* the route second-guess that rescues a stale
    /// `.connected`, so every later claim for that device was skipped
    /// silently for the life of the process.
    ///
    /// Observed on the reference Pixel: relay holder, connected,
    /// registering every 120s, no Bluetooth connection attempt for over
    /// half an hour, nothing logged. Restarting the process - which
    /// clears this map and nothing else - fixed it immediately.
    func testAConnectThatNeverResolvesTimesOutRatherThanStickingAtConnecting() async {
        let gateway = FakeBluetoothPeripheralGateway()
        gateway.blockNextConnect = true
        let manager = BluetoothConnectionManager(
            gateway: gateway,
            operationTimeout: .milliseconds(50)
        )

        do {
            try await manager.connect(deviceIdentifier: deviceIdentifier)
            XCTFail("expected the bounded connect to time out")
        } catch let error as BluetoothOperationTimedOut {
            XCTAssertEqual(error.deviceIdentifier, deviceIdentifier)
            XCTAssertEqual(error.operation, "connect")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // The property that matters: the state resolved. Before #244 it
        // stayed `.connecting` for the life of the process.
        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .disconnected)
    }

    /// The consequence of the above, and the actual user-visible bug: a
    /// later claim is attempted rather than silently dropped.
    func testAClaimAfterATimedOutConnectIsStillAttempted() async throws {
        let gateway = FakeBluetoothPeripheralGateway()
        gateway.blockNextConnect = true
        let manager = BluetoothConnectionManager(
            gateway: gateway,
            operationTimeout: .milliseconds(50)
        )

        _ = try? await manager.connect(deviceIdentifier: deviceIdentifier)
        try await manager.connect(deviceIdentifier: deviceIdentifier)

        XCTAssertEqual(
            gateway.connectCalls,
            [deviceIdentifier, deviceIdentifier],
            "a claim after a hung one must not be skipped - this is #244"
        )
        let state = await manager.connectionState(deviceIdentifier: deviceIdentifier)
        XCTAssertEqual(state, .connected)
    }

    func testTheTimeoutIsTheEightSecondsAdr0019Specifies() {
        // Must equal packages/protocol's COMMAND_OUTCOME_TIMEOUT_MS and
        // adapter-android's. Three hand-written copies of one number;
        // #206 criterion 2 requires they agree or the aggregate success
        // rate is meaningless.
        XCTAssertEqual(commandOutcomeTimeout, .seconds(8))
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
