import XCTest

private final class CooldownClock: @unchecked Sendable {
    var instant = ContinuousClock.now
    func read() -> ContinuousClock.Instant { instant }
}

@testable import AdapterMac

private let accountId = "acct-1"
private let nodeId = "mac-node-1"
private let headsetIdentifier = BluetoothDeviceIdentifier.identifier(forAddressString: "AA:BB:CC:DD:EE:FF")!
private let eventsTopicString = Topics.events(account: accountId, node: nodeId)
private let commandsTopicString = Topics.commands(account: accountId, node: nodeId)

private let manifest = NodeManifest(
    nodeId: nodeId,
    platform: .mac,
    displayName: "MacBook Air",
    adapterVersion: "0.0.0",
    supportedEventKinds: [.call, .voip]
)

/// Mirrors `adapter-android`'s `AndroidNodeTest.kt` test-for-test, using
/// the same two fakes (``FakeMqttTransport``, ``FakeBluetoothPeripheralGateway``)
/// this package already has for testing ``BluetoothConnectionManager`` in
/// isolation.
private final class Fixture {
    let transport = FakeMqttTransport()
    let gateway = FakeBluetoothPeripheralGateway()
    let bluetooth: BluetoothConnectionManager
    let node: MacNode

    init() {
        bluetooth = BluetoothConnectionManager(gateway: gateway)
        node = MacNode(
            accountId: accountId,
            nodeId: nodeId,
            headsetIdentifier: headsetIdentifier,
            transport: transport,
            bluetooth: bluetooth
        )
    }
}

final class MacNodeTests: XCTestCase {
    // MARK: - manual claim vs the self-cooldown (#212)

    /// The cooldown exists so thrw ignores its **own** side effects (#167).
    /// A manual claim is the user acting, not an echo, and ADR 0010 says
    /// direct user action always wins - so it must go out even inside the
    /// window. Without this the override button silently does nothing for
    /// three seconds after any switch, which is exactly when a user
    /// reaches for it.
    func testAManualClaimIsPublishedEvenInsideTheSelfCooldown() async throws {
        let cooldown = SelfCooldown()
        let transport = FakeMqttTransport()
        let node = MacNode(
            accountId: accountId,
            nodeId: nodeId,
            headsetIdentifier: headsetIdentifier,
            transport: transport,
            bluetooth: BluetoothConnectionManager(gateway: FakeBluetoothPeripheralGateway()),
            selfCooldown: cooldown
        )
        cooldown.arm()

        try await node.emitEvent(type: .manualClaim, priority: unrankedPriority)

        XCTAssertEqual(transport.published.count, 1, "a manual claim must not be suppressed by the cooldown")
    }

    func testReleasingAManualClaimIsAlsoPublishedInsideTheCooldown() async throws {
        let cooldown = SelfCooldown()
        let transport = FakeMqttTransport()
        let node = MacNode(
            accountId: accountId,
            nodeId: nodeId,
            headsetIdentifier: headsetIdentifier,
            transport: transport,
            bluetooth: BluetoothConnectionManager(gateway: FakeBluetoothPeripheralGateway()),
            selfCooldown: cooldown
        )
        cooldown.arm()

        try await node.endEvent(type: .manualClaim)

        XCTAssertEqual(transport.published.count, 1, "releasing must not be suppressed either")
    }

    /// The exemption is for `manual_claim` alone. Every other kind is
    /// observed rather than requested, so every other kind can legitimately
    /// be an echo of thrw's own action - suppressing those is the whole
    /// point of #167 and must not regress.
    func testEveryOtherTriggerIsStillSuppressedByTheCooldown() async throws {
        for kind in [EventKind.media, .voip, .call] {
            let cooldown = SelfCooldown()
            let transport = FakeMqttTransport()
            let node = MacNode(
                accountId: accountId,
                nodeId: nodeId,
                headsetIdentifier: headsetIdentifier,
                transport: transport,
                bluetooth: BluetoothConnectionManager(gateway: FakeBluetoothPeripheralGateway()),
                selfCooldown: cooldown
            )
            cooldown.arm()

            try await node.emitEvent(type: kind, priority: unrankedPriority)

            XCTAssertTrue(transport.published.isEmpty, "\(kind) must still be suppressed")
        }
    }

    // MARK: - activeEvents (#178)

    /// The point of the whole mechanism: a periodic registration has to
    /// tell the relay what is playing *now*, or a relay that lost its
    /// state stays blind to a node that is mid-playback.
    func testRegisterReportsTheTriggersThisNodeHasActive() async throws {
        let f = Fixture()

        try await f.node.emitEvent(type: .media, priority: unrankedPriority)
        try await f.node.register(manifest: manifest)

        let decoded = try decodeRegistration(f)
        XCTAssertEqual(decoded.activeEvents, [.media])
    }

    func testATriggerThatEndedIsNoLongerReported() async throws {
        let f = Fixture()

        try await f.node.emitEvent(type: .media, priority: unrankedPriority)
        try await f.node.endEvent(type: .media)
        try await f.node.register(manifest: manifest)

        XCTAssertEqual(try decodeRegistration(f).activeEvents, [])
    }

    /// The subtle one. ``SelfCooldown`` exists so thrw doesn't react to
    /// its own claim/release (#167) - a suppressed trigger was never told
    /// to the relay at all. Recording it here would smuggle it out on the
    /// next periodic registration and undo the suppression entirely.
    func testATriggerSuppressedByTheSelfCooldownIsNotReported() async throws {
        let cooldown = SelfCooldown()
        let transport = FakeMqttTransport()
        let node = MacNode(
            accountId: accountId,
            nodeId: nodeId,
            headsetIdentifier: headsetIdentifier,
            transport: transport,
            bluetooth: BluetoothConnectionManager(gateway: FakeBluetoothPeripheralGateway()),
            selfCooldown: cooldown
        )
        cooldown.arm()

        try await node.emitEvent(type: .media, priority: unrankedPriority)
        try await node.register(manifest: manifest)

        let sent = try XCTUnwrap(transport.published.first)
        let decoded = try JSONDecoder().decode(RegistrationPayload.self, from: Data(sent.payload.utf8))
        XCTAssertEqual(decoded.activeEvents, [], "a suppressed trigger must not leak out via registration")
    }

    private func decodeRegistration(_ f: Fixture) throws -> RegistrationPayload {
        let sent = try XCTUnwrap(f.transport.published.last)
        return try JSONDecoder().decode(RegistrationPayload.self, from: Data(sent.payload.utf8))
    }

    func testRegisterPublishesTheManifestOnTheNodesEventsTopicAtQoS1() async throws {
        let f = Fixture()

        try await f.node.register(manifest: manifest)

        XCTAssertEqual(f.transport.published.count, 1)
        let sent = try XCTUnwrap(f.transport.published.first)
        XCTAssertEqual(sent.topic, eventsTopicString)
        XCTAssertEqual(sent.qos, TopicQos.eventsQos)
        XCTAssertFalse(sent.retained)

        let decoded = try JSONDecoder().decode(RegistrationPayload.self, from: Data(sent.payload.utf8))
        XCTAssertEqual(decoded.kind, registrationKind)
        XCTAssertEqual(decoded.manifest, manifest)
    }

    func testEmitEventPublishesTypeAndPriorityToTheEventsTopicAtQoS1() async throws {
        let f = Fixture()

        try await f.node.emitEvent(type: .call, priority: 1)

        let sent = try XCTUnwrap(f.transport.published.first)
        XCTAssertEqual(sent.topic, eventsTopicString)
        XCTAssertEqual(sent.qos, TopicQos.eventsQos)
        XCTAssertFalse(sent.retained)

        let decoded = try JSONDecoder().decode(EventPayload.self, from: Data(sent.payload.utf8))
        XCTAssertEqual(decoded, EventPayload(type: .call, priority: 1))
    }

    func testEndEventPublishesAnEventEndEnvelopeOnTheEventsTopicAtQoS1() async throws {
        let f = Fixture()

        try await f.node.endEvent(type: .voip)

        let sent = try XCTUnwrap(f.transport.published.first)
        XCTAssertEqual(sent.topic, eventsTopicString)
        XCTAssertEqual(sent.qos, TopicQos.eventsQos)
        XCTAssertFalse(sent.retained)

        let decoded = try JSONDecoder().decode(EventEndPayload.self, from: Data(sent.payload.utf8))
        XCTAssertEqual(decoded, EventEndPayload(type: .voip))
        XCTAssertEqual(decoded.kind, eventEndKind)
    }

    func testEveryEventKindEmitsItsProtocolWireSpelling() async throws {
        let f = Fixture()
        let expected: [(EventKind, String)] = [
            (.call, "call"),
            (.manualClaim, "manual_claim"),
            (.voip, "voip"),
            (.media, "media"),
        ]

        for (index, pair) in expected.enumerated() {
            try await f.node.emitEvent(type: pair.0, priority: index)
        }

        XCTAssertEqual(f.transport.published.count, expected.count)
        for (sent, pair) in zip(f.transport.published, expected) {
            let decoded = try JSONDecoder().decode(EventPayload.self, from: Data(sent.payload.utf8))
            XCTAssertEqual(decoded.type, pair.0)
            XCTAssertTrue(sent.payload.contains("\"\(pair.1)\""), "expected wire spelling '\(pair.1)' in \(sent.payload)")
        }
    }

    func testOnClaimConnectsTheHeadsetThroughTheBluetoothConnectionManager() async throws {
        let f = Fixture()

        try await f.node.onClaim()

        XCTAssertEqual(f.gateway.connectCalls, [headsetIdentifier])
        let state = await f.bluetooth.connectionState(deviceIdentifier: headsetIdentifier)
        XCTAssertEqual(state, .connected)
    }

    func testOnReleaseDisconnectsTheHeadsetThroughTheBluetoothConnectionManager() async throws {
        let f = Fixture()
        try await f.node.onClaim()

        try await f.node.onRelease()

        XCTAssertEqual(f.gateway.disconnectCalls, [headsetIdentifier])
        let state = await f.bluetooth.connectionState(deviceIdentifier: headsetIdentifier)
        XCTAssertEqual(state, .disconnected)
    }

    func testClaimAndReleasePublishNothingTheRelayAlreadyKnowsItAsked() async throws {
        let f = Fixture()

        try await f.node.onClaim()
        try await f.node.onRelease()

        XCTAssertTrue(f.transport.published.isEmpty)
    }

    func testRelayCommandsOnTheCommandsTopicDriveClaimAndRelease() async throws {
        let f = Fixture()
        f.transport.sendCommand(#"{"type":"claim"}"#)
        f.transport.sendCommand(#"{"type":"release"}"#)
        f.transport.finishCommands()

        try await f.node.listenForCommands()

        XCTAssertEqual(f.transport.subscriptions, [Subscription(topic: commandsTopicString, qos: TopicQos.commandsQos)])
        XCTAssertEqual(f.gateway.connectCalls, [headsetIdentifier])
        XCTAssertEqual(f.gateway.disconnectCalls, [headsetIdentifier])
    }

    func testPublishHeartbeatPublishesAnEmptyPayloadOnTheHeartbeatTopicAtQoS0() async throws {
        let f = Fixture()

        try await f.node.publishHeartbeat()

        let sent = try XCTUnwrap(f.transport.published.first)
        XCTAssertEqual(sent.topic, Topics.heartbeat(account: accountId, node: nodeId))
        XCTAssertEqual(sent.qos, TopicQos.heartbeatQos)
        XCTAssertFalse(sent.retained)
        // Empty on purpose - arrival is the whole signal, and
        // relay-core's subscribeHeartbeat ignores the body (#142).
        XCTAssertEqual(sent.payload, "")
    }

    func testTheHeartbeatDoesNotRideTheEventsTopic() async throws {
        let f = Fixture()

        try await f.node.publishHeartbeat()

        let sent = try XCTUnwrap(f.transport.published.first)
        XCTAssertNotEqual(sent.topic, eventsTopicString)
    }

    /// #167 / ADR 0010 point 1: the audio-routing change thrw's own
    /// claim caused must not come straight back as a new trigger.
    func testATriggerReportedInsideTheSelfCooldownWindowIsSuppressed() async throws {
        let clock = CooldownClock()
        let transport = FakeMqttTransport()
        let node = MacNode(
            accountId: accountId, nodeId: nodeId, headsetIdentifier: headsetIdentifier,
            transport: transport, bluetooth: BluetoothConnectionManager(gateway: FakeBluetoothPeripheralGateway()),
            selfCooldown: SelfCooldown(window: .seconds(3), now: clock.read)
        )

        try await node.onClaim()
        try await node.emitEvent(type: .media, priority: 0)

        XCTAssertTrue(transport.published.isEmpty, "the self-inflicted trigger must not reach the relay")
    }

    func testTheSameTriggerIsReportedOnceTheWindowHasElapsed() async throws {
        let clock = CooldownClock()
        let transport = FakeMqttTransport()
        let node = MacNode(
            accountId: accountId, nodeId: nodeId, headsetIdentifier: headsetIdentifier,
            transport: transport, bluetooth: BluetoothConnectionManager(gateway: FakeBluetoothPeripheralGateway()),
            selfCooldown: SelfCooldown(window: .seconds(3), now: clock.read)
        )

        try await node.onClaim()
        clock.instant = clock.instant.advanced(by: .seconds(3))
        try await node.emitEvent(type: .media, priority: 0)

        XCTAssertEqual(transport.published.count, 1)
    }

    /// The cooldown stops thrw talking to itself; it must not make the
    /// node deaf to the relay.
    func testARelayCommandInsideTheWindowIsStillHonoured() async throws {
        let clock = CooldownClock()
        let transport = FakeMqttTransport()
        let gateway = FakeBluetoothPeripheralGateway()
        let node = MacNode(
            accountId: accountId, nodeId: nodeId, headsetIdentifier: headsetIdentifier,
            transport: transport, bluetooth: BluetoothConnectionManager(gateway: gateway),
            selfCooldown: SelfCooldown(window: .seconds(3), now: clock.read)
        )

        try await node.onRelease()
        transport.sendCommand(#"{"type":"claim"}"#)
        transport.finishCommands()
        try await node.listenForCommands()

        XCTAssertEqual(gateway.connectCalls, [headsetIdentifier], "a relay CLAIM must still connect during cooldown")
    }

    func testAnUnparseableCommandIsSkippedWithoutDroppingTheSubscription() async throws {
        let f = Fixture()
        f.transport.sendCommand("not json")
        f.transport.sendCommand(#"{"type":"teleport"}"#)
        f.transport.sendCommand(#"{"type":"claim"}"#)
        f.transport.finishCommands()

        try await f.node.listenForCommands()

        XCTAssertEqual(f.gateway.connectCalls, [headsetIdentifier])
    }
}

/// #210. The relay stamps every command with `seq` and `epoch`. This
/// adapter does not read them yet, and must keep working while it does
/// not — that is the whole basis for shipping the relay half first.
///
/// Asserted against the **exact bytes** a real relay emits, captured from
/// the wire on 2026-09-20 rather than hand-written from the type:
///
///     {"type":"claim","seq":1,"epoch":"2174ac4b-0ab7-4cff-967e-8a352e3bd7c8"}
final class CommandPayloadForwardCompatibilityTests: XCTestCase {
    func testDecodesACommandCarryingSequencingFieldsItDoesNotKnowAbout() throws {
        let wire = #"{"type":"claim","seq":1,"epoch":"2174ac4b-0ab7-4cff-967e-8a352e3bd7c8"}"#

        let decoded = try JSONDecoder().decode(CommandPayload.self, from: Data(wire.utf8))

        XCTAssertEqual(decoded.type, .claim)
    }

    func testDecodesAReleaseTheSameWay() throws {
        let wire = #"{"type":"release","seq":9,"epoch":"any"}"#

        XCTAssertEqual(try JSONDecoder().decode(CommandPayload.self, from: Data(wire.utf8)).type, .release)
    }

    /// The guarantee is *unknown fields are ignored*, not *these two
    /// specific fields*. A relay that grows a third must not break this
    /// adapter either.
    func testAnUnrecognisedFieldIsIgnored() throws {
        let wire = #"{"type":"claim","seq":1,"epoch":"e","somethingAddedLater":{"a":[1,2]}}"#

        XCTAssertEqual(try JSONDecoder().decode(CommandPayload.self, from: Data(wire.utf8)).type, .claim)
    }
}
