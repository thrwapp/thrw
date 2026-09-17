import Foundation

/// Thin seam over the platform Bluetooth connect and disconnect calls
/// that ``BluetoothConnectionManager`` depends on. Implemented for real
/// by ``IOBluetoothPeripheralGateway`` (classic Bluetooth, via
/// `IOBluetoothDevice`).
///
/// Modeled on `packages/adapter-android`'s `BluetoothClassicGateway`:
/// real Bluetooth hardware isn't available on the CI runner (no
/// GitHub-hosted macOS runner has Bluetooth), so
/// `BluetoothConnectionManager`'s own state-tracking logic is tested
/// against a fake conforming to this protocol, never against the
/// Bluetooth framework's own types directly.
///
/// The signatures here are deliberately platform-agnostic — swapping the
/// implementation underneath from CoreBluetooth to `IOBluetooth` (#101)
/// changed nothing above this line.
public protocol BluetoothPeripheralGateway: Sendable {
    /// Connects to the device identified by `deviceIdentifier` (see
    /// ``BluetoothDeviceIdentifier`` for how a classic-Bluetooth address
    /// is carried in one). Throws if the device can't be found among the
    /// ones already paired with this host, or if the Bluetooth stack
    /// reports a connection failure.
    func connect(deviceIdentifier: UUID) async throws

    /// Disconnects the device identified by `deviceIdentifier`. Throws
    /// if the Bluetooth stack reports a disconnection error.
    func disconnect(deviceIdentifier: UUID) async throws
}
