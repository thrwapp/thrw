import Foundation

/// Thin seam over CoreBluetooth's `CBCentralManager`/`CBPeripheral`
/// connect and disconnect calls that ``BluetoothConnectionManager``
/// depends on.
///
/// Modeled on `packages/adapter-android`'s `BluetoothClassicGateway`:
/// real Bluetooth hardware isn't available on the CI runner (no
/// GitHub-hosted macOS runner has Bluetooth), so
/// `BluetoothConnectionManager`'s own state-tracking logic is tested
/// against a fake conforming to this protocol, never against
/// CoreBluetooth's own types directly.
public protocol BluetoothPeripheralGateway: Sendable {
    /// Connects to the peripheral identified by `deviceIdentifier`
    /// (CoreBluetooth's `CBPeripheral.identifier`). Throws if the
    /// peripheral can't be found among previously known (paired)
    /// peripherals, or if CoreBluetooth reports a connection failure.
    func connect(deviceIdentifier: UUID) async throws

    /// Disconnects the peripheral identified by `deviceIdentifier`.
    /// Throws if CoreBluetooth reports a disconnection error.
    func disconnect(deviceIdentifier: UUID) async throws
}
