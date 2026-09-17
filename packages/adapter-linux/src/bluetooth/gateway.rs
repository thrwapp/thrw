use std::fmt;

/// Thin seam over the platform Bluetooth connect/disconnect calls that
/// [`super::BluetoothConnectionManager`] depends on - the Linux analog of
/// adapter-mac's `BluetoothPeripheralGateway` (CoreBluetooth/IOBluetooth)
/// and adapter-android's `BluetoothClassicGateway`
/// (`android.bluetooth`). The real implementation
/// ([`super::BluezBluetoothGateway`]) talks to BlueZ over D-Bus; tests
/// fake this trait directly rather than mocking D-Bus, the same approach
/// the other two adapters take for their own OS Bluetooth stacks.
pub trait BluetoothGateway: Send + Sync {
    /// Connects to the already-paired device identified by
    /// `device_address`. Implementations never pair or scan - the device
    /// must already be known to the platform's Bluetooth stack.
    fn connect(
        &self,
        device_address: &str,
    ) -> impl std::future::Future<Output = Result<(), BluetoothGatewayError>> + Send;

    /// Disconnects the device identified by `device_address`.
    fn disconnect(
        &self,
        device_address: &str,
    ) -> impl std::future::Future<Output = Result<(), BluetoothGatewayError>> + Send;
}

/// Error returned by a [`BluetoothGateway`]. Carries the underlying
/// platform error's message rather than the platform's own error type,
/// so this stays free of BlueZ/D-Bus-specific types and the fake
/// implementation can construct it without any real dependency.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BluetoothGatewayError {
    ConnectFailed(String),
    DisconnectFailed(String),
}

impl fmt::Display for BluetoothGatewayError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BluetoothGatewayError::ConnectFailed(message) => {
                write!(f, "bluetooth connect failed: {message}")
            }
            BluetoothGatewayError::DisconnectFailed(message) => {
                write!(f, "bluetooth disconnect failed: {message}")
            }
        }
    }
}

impl std::error::Error for BluetoothGatewayError {}
