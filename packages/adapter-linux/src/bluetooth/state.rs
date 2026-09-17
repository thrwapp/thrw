/// Per-device connection state tracked by [`super::BluetoothConnectionManager`].
///
/// Mirrors `BluetoothConnectionState` on adapter-mac (Swift enum) and
/// adapter-android (Kotlin enum) - same four states, same meaning, just
/// the Rust idiom of the concept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BluetoothConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
}
