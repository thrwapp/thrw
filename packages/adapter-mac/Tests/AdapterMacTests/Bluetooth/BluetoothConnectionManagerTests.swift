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
