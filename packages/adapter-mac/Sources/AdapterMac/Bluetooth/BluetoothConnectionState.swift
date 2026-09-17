/// Per-device connection state tracked by ``BluetoothConnectionManager``.
public enum BluetoothConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}
