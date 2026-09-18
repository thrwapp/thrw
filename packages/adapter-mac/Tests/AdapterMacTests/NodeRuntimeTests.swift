import XCTest

@testable import AdapterMac

private let runtimeAccountId = "acct-1"
private let runtimeNodeId = "mac-node-1"
private let runtimeHeadsetIdentifier = BluetoothDeviceIdentifier.identifier(forAddressString: "AA:BB:CC:DD:EE:FF")!
private let runtimeEventsTopic = Topics.events(account: runtimeAccountId, node: runtimeNodeId)
private let runtimeCommandsTopic = Topics.commands(account: runtimeAccountId, node: runtimeNodeId)

private let runtimeManifest = NodeManifest(
    nodeId: runtimeNodeId,
    platform: .mac,
    displayName: "MacBook Air",
    adapterVersion: "0.0.0",
    supportedEventKinds: [.voip]
)

/// Tests ``NodeRuntime`` - the composition root's testable half (#128's
/// acceptance criterion 5). `AdapterMacApp`'s `AppDelegate`, the
/// untestable half that constructs the real `NSApplication` status item
/// and the real `MQTTNIOTransport`/`IOBluetoothPeripheralGateway`-backed
/// dependencies, is exercised by none of this - see
/// docs/handoffs/128.md for what is and isn't covered.
///
/// `@MainActor` because ``NodeRuntime`` is (see its own kdoc for why) -
/// no run loop, host app or AppKit type is needed for any of this.
/// Never emits, so the media monitor (#166) stays inert in tests about
/// the other tasks.
private struct SilentAudioSource: AudioPlaybackSource {
    func events() -> AsyncStream<AudioPlaybackEvent> { AsyncStream { $0.finish() } }
}

@MainActor
final class NodeRuntimeTests: XCTestCase {
    private func makeNode(transport: FakeMqttTransport, gateway: FakeBluetoothPeripheralGateway) -> MacNode {
        MacNode(
            accountId: runtimeAccountId,
            nodeId: runtimeNodeId,
            headsetIdentifier: runtimeHeadsetIdentifier,
            transport: transport,
            bluetooth: BluetoothConnectionManager(gateway: gateway)
        )
    }

    /// The tasks `start` launches are unstructured, so a test has to
    /// give them a chance to run before asserting. Polls rather than
    /// sleeping a fixed interval: fast when the work is already done,
    /// and not flaky when the machine is loaded.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    func testStartRegistersTheGivenManifestOnTheNodesEventsTopic() async throws {
        let transport = FakeMqttTransport()
        let node = makeNode(transport: transport, gateway: FakeBluetoothPeripheralGateway())
        let source = FakeRunningApplicationSource()
        let runtime = NodeRuntime(
            node: node,
            voipTriggerMonitor: VoipTriggerMonitor(source: source, node: node),
            mediaTriggerMonitor: MediaTriggerMonitor(source: SilentAudioSource(), node: node)
        )

        let handle = runtime.start(manifest: runtimeManifest)
        defer { handle.cancel() }

        await waitUntil("the registration to be published") {
            transport.published.contains { $0.topic == runtimeEventsTopic }
        }

        // By topic, not by position: the heartbeat task (#142) also
        // publishes, so `published.first` is only the registration by
        // virtue of an ordering guarantee tested separately below.
        let sent = try XCTUnwrap(transport.published.first { $0.topic == runtimeEventsTopic })
        XCTAssertEqual(sent.topic, runtimeEventsTopic)
        let decoded = try JSONDecoder().decode(RegistrationPayload.self, from: Data(sent.payload.utf8))
        XCTAssertEqual(decoded.kind, registrationKind)
        XCTAssertEqual(decoded.manifest, runtimeManifest)
    }

    func testStartSubscribesToTheNodesOwnCommandsTopicAtQoS1() async throws {
        let transport = FakeMqttTransport()
        let node = makeNode(transport: transport, gateway: FakeBluetoothPeripheralGateway())
        let source = FakeRunningApplicationSource()
        let runtime = NodeRuntime(
            node: node,
            voipTriggerMonitor: VoipTriggerMonitor(source: source, node: node),
            mediaTriggerMonitor: MediaTriggerMonitor(source: SilentAudioSource(), node: node)
        )

        let handle = runtime.start(manifest: runtimeManifest)
        defer { handle.cancel() }

        await waitUntil("the commands subscription") { !transport.subscriptions.isEmpty }

        XCTAssertEqual(
            transport.subscriptions,
            [Subscription(topic: runtimeCommandsTopic, qos: TopicQos.commandsQos)]
        )
    }

    func testStartWiresTheVoipTriggerMonitorThroughToTheRelay() async throws {
        let transport = FakeMqttTransport()
        let node = makeNode(transport: transport, gateway: FakeBluetoothPeripheralGateway())
        let source = FakeRunningApplicationSource()
        let runtime = NodeRuntime(
            node: node,
            voipTriggerMonitor: VoipTriggerMonitor(source: source, node: node),
            mediaTriggerMonitor: MediaTriggerMonitor(source: SilentAudioSource(), node: node)
        )

        let handle = runtime.start(manifest: runtimeManifest)
        defer { handle.cancel() }

        // Filter to the events topic rather than indexing `published`
        // positionally: since #142 the heartbeat task publishes to its
        // own topic on its own schedule, so position in the combined
        // array is no longer a reliable way to find trigger payloads.
        func eventsPayloads() -> [String] {
            transport.published.filter { $0.topic == runtimeEventsTopic }.map(\.payload)
        }

        // The registration goes out first, on its own task - wait for it
        // so the trigger payloads below are unambiguously the monitor's.
        await waitUntil("the registration to be published") { !eventsPayloads().isEmpty }

        let zoom = RunningApplicationInfo(bundleIdentifier: "us.zoom.xos")
        source.send(.launched(zoom))
        await waitUntil("the voip event") { eventsPayloads().count >= 2 }

        source.send(.terminated(zoom))
        await waitUntil("the voip event_end") { eventsPayloads().count >= 3 }

        let triggerPayloads = Array(eventsPayloads().dropFirst())
        let event = try JSONDecoder().decode(EventPayload.self, from: Data(triggerPayloads[0].utf8))
        XCTAssertEqual(event, EventPayload(type: .voip, priority: unrankedPriority))
        let eventEnd = try JSONDecoder().decode(EventEndPayload.self, from: Data(triggerPayloads[1].utf8))
        XCTAssertEqual(eventEnd.kind, eventEndKind)
        XCTAssertEqual(eventEnd.type, .voip)
    }

    func testRelayCommandsArrivingOnTheCommandsTopicDriveTheBluetoothGateway() async throws {
        let transport = FakeMqttTransport()
        let gateway = FakeBluetoothPeripheralGateway()
        let node = makeNode(transport: transport, gateway: gateway)
        let source = FakeRunningApplicationSource()
        let runtime = NodeRuntime(
            node: node,
            voipTriggerMonitor: VoipTriggerMonitor(source: source, node: node),
            mediaTriggerMonitor: MediaTriggerMonitor(source: SilentAudioSource(), node: node)
        )

        let handle = runtime.start(manifest: runtimeManifest)
        defer { handle.cancel() }

        await waitUntil("the commands subscription") { !transport.subscriptions.isEmpty }

        transport.sendCommand(#"{"type":"claim"}"#)
        await waitUntil("the claim to reach the gateway") { !gateway.connectCalls.isEmpty }
        XCTAssertEqual(gateway.connectCalls, [runtimeHeadsetIdentifier])

        transport.sendCommand(#"{"type":"release"}"#)
        await waitUntil("the release to reach the gateway") { !gateway.disconnectCalls.isEmpty }
        XCTAssertEqual(gateway.disconnectCalls, [runtimeHeadsetIdentifier])
    }

    /// The three tasks `start` launches must be independent: the
    /// commands subscription never completes on its own, so if they ran
    /// sequentially, neither the registration nor the trigger monitor
    /// would ever get to run at all.
    func testAllThreeLaunchedTasksRunIndependentlyOfEachOther() async throws {
        let transport = FakeMqttTransport()
        let node = makeNode(transport: transport, gateway: FakeBluetoothPeripheralGateway())
        let source = FakeRunningApplicationSource()
        let runtime = NodeRuntime(
            node: node,
            voipTriggerMonitor: VoipTriggerMonitor(source: source, node: node),
            mediaTriggerMonitor: MediaTriggerMonitor(source: SilentAudioSource(), node: node)
        )

        let handle = runtime.start(manifest: runtimeManifest)
        defer { handle.cancel() }

        // Registration (task 1) and the commands subscription (task 2)
        // both happen without the never-ending subscription blocking
        // anything...
        await waitUntil("the registration to be published") { !transport.published.isEmpty }
        await waitUntil("the commands subscription") { !transport.subscriptions.isEmpty }

        // ...and the monitor (task 3) is live too, still consuming its
        // source while the subscription remains open.
        //
        // Counts events-topic publishes specifically: a bare
        // `published.count >= 2` would be satisfied by the registration
        // plus a heartbeat (#142) even if the monitor were dead, which
        // would make this assertion pass for the wrong reason.
        source.send(.launched(RunningApplicationInfo(bundleIdentifier: "us.zoom.xos")))
        await waitUntil("the voip event") {
            transport.published.filter { $0.topic == runtimeEventsTopic }.count >= 2
        }
    }

    /// #142: the relay only subscribes to a node's heartbeat topic once
    /// it has seen that node register (`relay-service.ts`'s `handleEvent`
    /// -> `trackHeartbeat`), so a beat published before registration goes
    /// to a topic nothing is listening to. This ordering is a correctness
    /// property, not a test convenience.
    func testTheFirstHeartbeatIsNotPublishedBeforeRegistration() async throws {
        let transport = FakeMqttTransport()
        let node = makeNode(transport: transport, gateway: FakeBluetoothPeripheralGateway())
        let source = FakeRunningApplicationSource()
        let runtime = NodeRuntime(
            node: node,
            voipTriggerMonitor: VoipTriggerMonitor(source: source, node: node),
            mediaTriggerMonitor: MediaTriggerMonitor(source: SilentAudioSource(), node: node)
        )

        let handle = runtime.start(manifest: runtimeManifest)
        defer { handle.cancel() }

        await waitUntil("a heartbeat to be published") {
            transport.published.contains { $0.topic == Topics.heartbeat(account: runtimeAccountId, node: runtimeNodeId) }
        }

        let firstRegistration = transport.published.firstIndex { $0.topic == runtimeEventsTopic }
        let firstHeartbeat = transport.published.firstIndex {
            $0.topic == Topics.heartbeat(account: runtimeAccountId, node: runtimeNodeId)
        }
        XCTAssertNotNil(firstRegistration)
        XCTAssertNotNil(firstHeartbeat)
        XCTAssertLessThan(
            try XCTUnwrap(firstRegistration),
            try XCTUnwrap(firstHeartbeat),
            "the registration must be published before the first heartbeat"
        )
    }

    func testCancellingTheHandleStopsTheTriggerMonitor() async throws {
        let transport = FakeMqttTransport()
        let node = makeNode(transport: transport, gateway: FakeBluetoothPeripheralGateway())
        let source = FakeRunningApplicationSource()
        let runtime = NodeRuntime(
            node: node,
            voipTriggerMonitor: VoipTriggerMonitor(source: source, node: node),
            mediaTriggerMonitor: MediaTriggerMonitor(source: SilentAudioSource(), node: node)
        )

        let handle = runtime.start(manifest: runtimeManifest)
        await waitUntil("the registration to be published") { !transport.published.isEmpty }

        handle.cancel()
        // Ending the source's stream is what a cancelled `for await`
        // needs to unblock on - after which nothing further is published.
        source.finish()
        transport.finishCommands()
        let countAfterCancel = transport.published.count

        source.send(.launched(RunningApplicationInfo(bundleIdentifier: "us.zoom.xos")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(transport.published.count, countAfterCancel)
    }
}
