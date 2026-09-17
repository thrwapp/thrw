import Foundation

@testable import AdapterMac

/// Fakes the ``BluetoothPeripheralGateway`` boundary instead of mocking
/// CoreBluetooth's own classes directly — mirrors
/// `packages/adapter-android`'s `FakeBluetoothClassicGateway`.
final class FakeBluetoothPeripheralGateway: BluetoothPeripheralGateway, @unchecked Sendable {
    private(set) var connectCalls: [UUID] = []
    private(set) var disconnectCalls: [UUID] = []
    var failNextConnect = false
    var failNextDisconnect = false

    func connect(deviceIdentifier: UUID) async throws {
        connectCalls.append(deviceIdentifier)
        if failNextConnect {
            failNextConnect = false
            throw FakeGatewayError.simulatedFailure
        }
    }

    func disconnect(deviceIdentifier: UUID) async throws {
        disconnectCalls.append(deviceIdentifier)
        if failNextDisconnect {
            failNextDisconnect = false
            throw FakeGatewayError.simulatedFailure
        }
    }
}

enum FakeGatewayError: Error, Equatable {
    case simulatedFailure
}
