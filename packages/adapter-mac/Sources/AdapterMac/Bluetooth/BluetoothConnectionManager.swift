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

    /// #225 / ADR 0018 decision 3 - reads whether a device *actually*
    /// holds the audio route, so `connect` can second-guess its own
    /// cached `.connected`. Optional: without one, `connect` behaves
    /// exactly as it did before #225.
    private let routeSource: DeviceAudioRouteSource?

    public init(gateway: BluetoothPeripheralGateway, routeSource: DeviceAudioRouteSource? = nil) {
        self.gateway = gateway
        self.routeSource = routeSource
    }

    /// Connects to `deviceIdentifier`. A no-op if that device is already
    /// connected *and still holds the audio route*, or if a connection
    /// attempt is already in flight.
    ///
    /// On failure, state reverts to `.disconnected` and the underlying
    /// error is rethrown.
    ///
    /// ## Why `.connected` is not trusted on its own (#225)
    ///
    /// ADR 0018 decision 3: the skip must be decided on the actual
    /// route, not on this cached belief. The cache is exactly what a
    /// multipoint headset invalidates - the phone can take the route
    /// while this Mac keeps its Bluetooth link, leaving `states` saying
    /// `.connected` while audio plays somewhere else entirely. Measured
    /// on the reference hardware: the Mac reported the AirPods as
    /// `Connected` while its default output was `MacBook Air Speakers`
    /// and the phone held the route.
    ///
    /// Skipping in that state silently drops a claim that was genuinely
    /// needed - no log, no retry, no audio - which is why the ADR calls
    /// getting this wrong worse than getting decision 2 wrong.
    ///
    /// **Only `.connected` is second-guessed.** `.connecting` means a
    /// claim is already in flight and re-entering would issue a
    /// duplicate. A `nil` route reading means "cannot tell", which is no
    /// reason to override a cached state that may well be right.
    ///
    /// Mirrors `adapter-android`'s `BluetoothConnectionManager.connect`
    /// - change both together.
    public func connect(deviceIdentifier: UUID) async throws {
        switch states[deviceIdentifier] {
        case .connecting:
            return
        case .connected:
            guard routeSource?.holdsAudioRoute(deviceIdentifier: deviceIdentifier) == false else { return }
            states[deviceIdentifier] = .connecting
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
