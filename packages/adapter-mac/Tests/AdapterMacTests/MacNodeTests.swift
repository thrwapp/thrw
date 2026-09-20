import XCTest

private final class CooldownClock: @unchecked Sendable {
    var instant = ContinuousClock.now
    func read() -> ContinuousClock.Instant { instant }
}

@testable import AdapterMac

private let accountId = "acct-1"
private let nodeId = "mac-node-1"
private let headsetIdentifier = BluetoothDeviceIdentifier.identifier(forAddressString: "AA:BB:CC:DD:EE:FF")!
private let eventsTopicString = Topics.events(account: accountId, node: nodeId, resource: .audio)
private let commandsTopicString = Topics.commands(account: accountId, node: nodeId, resource: .audio)

private let manifest = NodeManifest(
    nodeId: nodeId,
    platform: .mac,
    displayName: "MacBook Air",
    adapterVersion: "0.0.0",
    supportedEventKinds: [.call, .voip],
    supportedResourceTypes: [.audio]
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
    /// #183, reproduced. A trigger that ends *inside* the self-cooldown
    /// window used to strand the relay with a signal that never ends.
    ///
    /// The monitor has already cleared its own flag by then and will
    /// never retry, so if the suppressed end also left the entry in
    /// `activeEvents`, every periodic registration would keep reporting
    /// the trigger as active - and #178's reconciliation would
    /// *perpetuate* the stranded signal rather than repair it.
    func testATriggerEndedInsideTheCooldownIsNotLeftReportedAsActive() async throws {
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

        try await node.emitEvent(type: .media, priority: unrankedPriority)
        cooldown.arm()
        try await node.endEvent(type: .media)
        try await node.register(manifest: manifest)

        let sent = try XCTUnwrap(transport.published.last)
        let decoded = try JSONDecoder().decode(RegistrationPayload.self, from: Data(sent.payload.utf8))
        XCTAssertEqual(
            decoded.activeEvents,
            [],
            "a suppressed end must not leave the trigger reported as active - #178 would keep it alive"
        )
    }

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

    /// #210 / ADR 0018 decision 1, end to end through the node rather
    /// than against the gate alone.
    ///
    /// Commands ride MQTT at QoS 1 - at-*least*-once - so the broker is
    /// entitled to redeliver, and does on reconnect. The redelivered
    /// claim here arrives after a newer release, and acting on it would
    /// take the headset back from whichever device now holds it.
    func testAClaimRedeliveredAfterANewerReleaseDoesNotReconnect() async throws {
        let f = Fixture()
        f.transport.sendCommand(#"{"type":"claim","seq":1,"epoch":"e1"}"#)
        f.transport.sendCommand(#"{"type":"release","seq":2,"epoch":"e1"}"#)
        f.transport.sendCommand(#"{"type":"claim","seq":1,"epoch":"e1"}"#)
        f.transport.finishCommands()

        try await f.node.listenForCommands()

        XCTAssertEqual(f.gateway.connectCalls, [headsetIdentifier], "the redelivered claim must not reconnect")
        XCTAssertEqual(f.gateway.disconnectCalls, [headsetIdentifier])
    }

    /// The relay restarted: new epoch, counters back to 1. Every command
    /// is below this node's mark and must be acted on anyway, or the
    /// system deadlocks until adapter state is cleared by hand.
    func testACommandFromANewRelayEpochIsActedOnEvenThoughItsSeqIsLower() async throws {
        let f = Fixture()
        f.transport.sendCommand(#"{"type":"claim","seq":9,"epoch":"e1"}"#)
        f.transport.sendCommand(#"{"type":"release","seq":1,"epoch":"e2"}"#)
        f.transport.finishCommands()

        try await f.node.listenForCommands()

        XCTAssertEqual(f.gateway.connectCalls, [headsetIdentifier])
        XCTAssertEqual(f.gateway.disconnectCalls, [headsetIdentifier], "a new epoch resets the mark")
    }

    /// The relay half of #210 shipped before this half, so a build of
    /// this adapter has already run against a relay that stamped
    /// nothing. A node that discarded unsequenced commands would be
    /// completely deaf rather than merely unprotected.
    func testAnUnsequencedCommandIsStillHonoured() async throws {
        let f = Fixture()
        f.transport.sendCommand(#"{"type":"claim","seq":5,"epoch":"e1"}"#)
        f.transport.sendCommand(#"{"type":"release"}"#)
        f.transport.finishCommands()

        try await f.node.listenForCommands()

        XCTAssertEqual(f.gateway.disconnectCalls, [headsetIdentifier])
    }

    /// A claim that throws has not happened - the headset was off, out
    /// of range or busy. The mark must stay where it is so the broker's
    /// redelivery gets to retry it, rather than being marked done and
    /// discarded forever.
    ///
    /// Note what this test has to do that `AndroidNodeTest`'s twin does
    /// not: call `listenForCommands` a second time. On Android a failing
    /// command is caught and the subscription survives (#161); here the
    /// error propagates out and ends the loop for good. That is a real
    /// bug - one failed claim leaves this Mac permanently deaf - but it
    /// predates #210 and is filed as **#223** rather than fixed here.
    /// Until it is, the retry has to be exercised across two calls.
    func testACommandThatFailedIsRetriedWhenItIsRedelivered() async throws {
        // One gateway and one gate across both attempts - the same
        // headset and the same persisted mark, which is what makes this
        // a redelivery rather than two unrelated commands.
        let gateway = FakeBluetoothPeripheralGateway()
        let gate = CommandSequenceGate(store: InMemorySequenceStore())
        let wire = #"{"type":"claim","seq":1,"epoch":"e1"}"#

        func node(_ transport: FakeMqttTransport) -> MacNode {
            MacNode(
                accountId: accountId, nodeId: nodeId, headsetIdentifier: headsetIdentifier,
                transport: transport, bluetooth: BluetoothConnectionManager(gateway: gateway),
                sequenceGate: gate
            )
        }

        gateway.failNextConnect = true
        let first = FakeMqttTransport()
        first.sendCommand(wire)
        first.finishCommands()
        do {
            try await node(first).listenForCommands()
            XCTFail("the failing claim should have propagated")
        } catch {}

        let second = FakeMqttTransport()
        second.sendCommand(wire)
        second.finishCommands()
        try await node(second).listenForCommands()

        XCTAssertEqual(
            gateway.connectCalls,
            [headsetIdentifier, headsetIdentifier],
            "the failed claim must be retryable"
        )
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

/// #210. The relay stamps every command with `seq` and `epoch`.
///
/// These tests were written for the relay half, when this adapter did
/// **not** read the fields and had to keep working anyway - the whole
/// basis for shipping the two halves separately. The adapter half now
/// reads them, so the assertions below also pin that the values decode
/// rather than merely that the message survives.
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
        XCTAssertEqual(decoded.seq, 1)
        XCTAssertEqual(decoded.epoch, "2174ac4b-0ab7-4cff-967e-8a352e3bd7c8")
    }

    func testDecodesAReleaseTheSameWay() throws {
        let wire = #"{"type":"release","seq":9,"epoch":"any"}"#

        let decoded = try JSONDecoder().decode(CommandPayload.self, from: Data(wire.utf8))

        XCTAssertEqual(decoded.type, .release)
        XCTAssertEqual(decoded.seq, 9)
    }

    /// The pre-#210 wire shape, which a relay older than this adapter
    /// still emits. Both fields must decode as absent rather than
    /// failing - `CommandSequenceGate` treats that as acceptable.
    func testACommandWithNoSequencingFieldsDecodesWithBothAbsent() throws {
        let decoded = try JSONDecoder().decode(CommandPayload.self, from: Data(#"{"type":"claim"}"#.utf8))

        XCTAssertEqual(decoded.type, .claim)
        XCTAssertNil(decoded.seq)
        XCTAssertNil(decoded.epoch)
    }

    /// The guarantee is *unknown fields are ignored*, not *these two
    /// specific fields*. A relay that grows a third must not break this
    /// adapter either.
    func testAnUnrecognisedFieldIsIgnored() throws {
        let wire = #"{"type":"claim","seq":1,"epoch":"e","somethingAddedLater":{"a":[1,2]}}"#

        XCTAssertEqual(try JSONDecoder().decode(CommandPayload.self, from: Data(wire.utf8)).type, .claim)
    }
}
