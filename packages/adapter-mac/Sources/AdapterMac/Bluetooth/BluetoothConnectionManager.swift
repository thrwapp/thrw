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

    /// #244. Injectable purely so tests don't wait on wall time - the
    /// same reasoning `HeartbeatPublisher`'s injectable `sleep` uses.
    /// Production callers take ``commandOutcomeTimeout``.
    ///
    /// Bounds **both** operations as of #303. It was `connectTimeout`
    /// when only `connect` was bounded; a release that never resolves
    /// wedges this state machine the same way a claim does, and one
    /// bound for both is also what ADR 0019 means by every command
    /// resolving within the same window.
    private let operationTimeout: Duration

    public init(
        gateway: BluetoothPeripheralGateway,
        routeSource: DeviceAudioRouteSource? = nil,
        operationTimeout: Duration = commandOutcomeTimeout
    ) {
        self.gateway = gateway
        self.routeSource = routeSource
        self.operationTimeout = operationTimeout
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
    /// ## Why `.connecting` is now bounded (#244)
    ///
    /// The `.connecting` skip above is correct for a claim that really
    /// is in flight, and wrong for one that never completed. Before
    /// #244 nothing guaranteed the second case could not happen: if
    /// `gateway.connect` never returned, neither the success nor the
    /// `catch` path ran, `states` stayed at `.connecting`, and **every
    /// subsequent claim for that device was skipped silently for the
    /// life of the process** - no log, no retry, no audio.
    ///
    /// That is not hypothetical. On the reference Pixel the phone was
    /// the relay's holder, connected, registering every 120s, and made
    /// no Bluetooth connection attempt for over half an hour; the only
    /// external symptom was a `route_drift` every two minutes with no
    /// reason attached. Restarting the process - which clears this map
    /// and nothing else - fixed it immediately.
    ///
    /// The bound is ``commandOutcomeTimeout``, so the state machine
    /// always resolves: either `.connected`, or `.disconnected` with an
    /// error thrown. ADR 0018 decision 3's route second-guess rescued a
    /// stale `.connected`; this is the same protection for `.connecting`,
    /// which it did not cover.
    ///
    /// Mirrors `adapter-android`'s `BluetoothConnectionManager.connect`
    /// - change both together.
    public func connect(deviceIdentifier: UUID) async throws {
        switch states[deviceIdentifier] {
        case .connecting:
            // #244 criterion 2. Skipping a genuinely concurrent claim is
            // correct; doing it silently is what made the stuck case
            // undiagnosable from outside.
            logAdapterInfo(
                category: "BluetoothConnectionManager",
                "claim skipped: a connect is already in flight for \(deviceIdentifier)"
            )
            return
        case .connected:
            guard routeSource?.holdsAudioRoute(deviceIdentifier: deviceIdentifier) == false else {
                logAdapterInfo(
                    category: "BluetoothConnectionManager",
                    "claim skipped: already connected and holding the route for \(deviceIdentifier)"
                )
                return
            }
            states[deviceIdentifier] = .connecting
        case .disconnected, .disconnecting, .none:
            states[deviceIdentifier] = .connecting
        }

        do {
            let gateway = self.gateway
            try await withBluetoothTimeout(
                operationTimeout,
                deviceIdentifier: deviceIdentifier,
                operation: "connect"
            ) {
                try await gateway.connect(deviceIdentifier: deviceIdentifier)
            }
            states[deviceIdentifier] = .connected
        } catch {
            states[deviceIdentifier] = .disconnected
            if error is BluetoothOperationTimedOut {
                logAdapterError(
                    category: "BluetoothConnectionManager",
                    "connect did not resolve within \(operationTimeout) for \(deviceIdentifier) - giving up so later claims are not skipped"
                )
            }
            throw error
        }
    }

    /// Disconnects `deviceIdentifier`. A no-op if that device is
    /// unknown, already disconnected, or already disconnecting.
    ///
    /// State always ends at `.disconnected`, whether or not the
    /// underlying gateway call succeeds — the error (if any) still
    /// propagates to the caller.
    ///
    /// ## Why this is bounded too (#303)
    ///
    /// "State always ends at `.disconnected`" was only true if this
    /// frame unwound, and an unbounded `await` on the gateway is exactly
    /// the case where it does not.
    /// ``IOBluetoothPeripheralGateway/disconnect`` suspends on a
    /// continuation resumed by a one-shot disconnect notification; if
    /// that never arrives, the `defer` never runs, `states` stays at
    /// `.disconnecting` - which the switch above skips - and every later
    /// release for that device is a silent no-op for the life of the
    /// process. That is #244's claim-side wedge with the arrow reversed,
    /// and ADR 0002's sequential handoff makes it worse: the winning
    /// device cannot take the route until the losing one lets go, so a
    /// stuck release strands the claim queued behind it.
    public func disconnect(deviceIdentifier: UUID) async throws {
        switch states[deviceIdentifier] {
        case nil, .disconnected, .disconnecting:
            return
        case .connected, .connecting:
            states[deviceIdentifier] = .disconnecting
        }

        defer { states[deviceIdentifier] = .disconnected }
        do {
            let gateway = self.gateway
            try await withBluetoothTimeout(
                operationTimeout,
                deviceIdentifier: deviceIdentifier,
                operation: "disconnect"
            ) {
                try await gateway.disconnect(deviceIdentifier: deviceIdentifier)
            }
        } catch is BluetoothOperationTimedOut {
            logAdapterError(
                category: "BluetoothConnectionManager",
                "disconnect did not resolve within \(operationTimeout) for \(deviceIdentifier) - giving up so the release still reports an outcome"
            )
            throw BluetoothOperationTimedOut(deviceIdentifier: deviceIdentifier, operation: "disconnect")
        }
    }

    /// Current known connection state for `deviceIdentifier`; unknown
    /// devices report `.disconnected`.
    public func connectionState(deviceIdentifier: UUID) -> BluetoothConnectionState {
        states[deviceIdentifier] ?? .disconnected
    }
}
