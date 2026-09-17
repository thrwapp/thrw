import XCTest

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
