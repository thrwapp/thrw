import Foundation

/// Errors a ``BluetoothPeripheralGateway`` implementation can throw.
/// Distinct from whatever status the underlying Bluetooth framework
/// itself reports — where there is one, it's carried along in `status`
/// rather than flattened away.
///
/// Deliberately free of any `IOBluetooth`/`IOKit` types (`status` is a
/// plain `Int32`, which is what `IOReturn` is a typealias for) so this
/// enum — and the tests that assert on it — compile on any platform,
/// not just macOS.
public enum BluetoothGatewayError: Error, Equatable {
    /// `deviceIdentifier` isn't one of ``BluetoothDeviceIdentifier``'s
    /// address-derived identifiers, so no Bluetooth address can be
    /// recovered from it. Nothing to connect to.
    case unrecognizedDeviceIdentifier(UUID)

    /// The Bluetooth address encoded in `deviceIdentifier` isn't among
    /// the devices macOS has already paired. This gateway never pairs
    /// and never runs a device inquiry — see
    /// ``IOBluetoothPeripheralGateway``'s documentation.
    case deviceNotPaired(UUID)

    /// The classic-Bluetooth baseband connection failed, with the
    /// `IOReturn` status the framework reported.
    case connectFailed(UUID, status: Int32)

    /// Closing the classic-Bluetooth baseband connection failed, with
    /// the `IOReturn` status the framework reported.
    case disconnectFailed(UUID, status: Int32)
}
