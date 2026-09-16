package com.thrw.adapter.android.bluetooth

/** Per-device connection state tracked by [BluetoothConnectionManager]. */
enum class BluetoothConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
}
