import Foundation

/// Manages Bluetooth connect/disconnect for a single paired headset at a
/// time (per ADR 0002: sequential handoff, not multipoint — this type
/// has no notion of "the other device", it just tracks state per
/// identifier).
///
/// This is local device control only. It does not talk to a relay, does
/// not implement the node interface (register/emitEvent/onClaim/
/// onRelease), and does not do any trigger detection — those are
/// separate follow-up issues, mirroring how `packages/adapter-android`
/// split #66 -> #67 -> #68.
///
/// An `actor` (rather than a manually-locked class) is the structured-
/// concurrency equivalent of the Android manager's `Mutex`-guarded state:
/// actor isolation serializes access to `states` for free.
public actor BluetoothConnectionManager {
    private let gateway: BluetoothPeripheralGateway
    private var states: [UUID: BluetoothConnectionState] = [:]

    public init(gateway: BluetoothPeripheralGateway) {
        self.gateway = gateway
    }

    /// Connects to `deviceIdentifier`. A no-op if that device is already
    /// connected or a connection attempt is already in flight.
    ///
    /// On failure, state reverts to `.disconnected` and the underlying
    /// error is rethrown.
    public func connect(deviceIdentifier: UUID) async throws {
        switch states[deviceIdentifier] {
        case .connected, .connecting:
            return
        case .disconnected, .disconnecting, .none:
            states[deviceIdentifier] = .connecting
        }

        do {
            try await gateway.connect(deviceIdentifier: deviceIdentifier)
            states[deviceIdentifier] = .connected
        } catch {
            states[deviceIdentifier] = .disconnected
            throw error
        }
    }

    /// Disconnects `deviceIdentifier`. A no-op if that device is
    /// unknown, already disconnected, or already disconnecting.
    ///
    /// State always ends at `.disconnected`, whether or not the
    /// underlying gateway call succeeds — the error (if any) still
    /// propagates to the caller.
    public func disconnect(deviceIdentifier: UUID) async throws {
        switch states[deviceIdentifier] {
        case nil, .disconnected, .disconnecting:
            return
        case .connected, .connecting:
            states[deviceIdentifier] = .disconnecting
        }

        defer { states[deviceIdentifier] = .disconnected }
        try await gateway.disconnect(deviceIdentifier: deviceIdentifier)
    }

    /// Current known connection state for `deviceIdentifier`; unknown
    /// devices report `.disconnected`.
    public func connectionState(deviceIdentifier: UUID) -> BluetoothConnectionState {
        states[deviceIdentifier] ?? .disconnected
    }
}
