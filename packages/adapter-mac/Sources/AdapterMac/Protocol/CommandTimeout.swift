import Foundation

/// The bound every adapter enforces on a claim or release (ADR 0019).
///
/// **This must stay equal to `packages/protocol`'s
/// `COMMAND_OUTCOME_TIMEOUT_MS` and `adapter-android`'s
/// `COMMAND_OUTCOME_TIMEOUT_MS`.** There are three hand-written
/// declarations of one number and nothing else catches them drifting —
/// the same situation as the heartbeat interval, which carries the same
/// warning for the same reason.
///
/// #206 criterion 2 is explicit that it be identical everywhere: an
/// adapter choosing its own bound makes the aggregate switch success
/// rate meaningless, because an outcome would not mean the same thing
/// in every row of the resulting data.
///
/// It guarantees **termination, not latency**. ADR 0007 owns latency,
/// with its own 3.5-4s p95 SLO; a claim settles in 3-5s on the
/// reference hardware, so this is roughly 2x headroom. If switches look
/// slow, the bug is elsewhere — changing this only changes how long a
/// stuck command hangs before it gives up.
public let commandOutcomeTimeout: Duration = .seconds(8)

/// A gateway call that did not resolve within ``commandOutcomeTimeout``
/// (#244).
///
/// Its own type rather than a generic error so callers — and ADR 0019's
/// outcome reporting, when it lands — can tell "the headset refused" from
/// "the stack never answered". Those are different failures with
/// different reason codes (`target_device_unreachable` vs `timed_out`)
/// and lumping them together would hide the second entirely, which is
/// exactly how #244 stayed invisible.
public struct BluetoothOperationTimedOut: Error, Equatable {
    public let deviceIdentifier: UUID
    public let operation: String

    public init(deviceIdentifier: UUID, operation: String) {
        self.deviceIdentifier = deviceIdentifier
        self.operation = operation
    }
}

/// Runs `operation`, throwing ``BluetoothOperationTimedOut`` if it has
/// not finished within `timeout`.
///
/// A free function rather than a method on the actor: the task group's
/// child closures are `@Sendable` and must not be actor-isolated, and
/// keeping this outside the actor makes that structural rather than
/// something to remember.
///
/// The losing child is always cancelled — without the `cancelAll` a
/// completed connect would leave its sleep task alive for the rest of
/// the window, and a timed-out connect would leave the gateway call
/// running unattended, still able to mutate the Bluetooth stack after
/// the manager has given up on it.
func withBluetoothTimeout(
    _ timeout: Duration,
    deviceIdentifier: UUID,
    operation: String,
    _ body: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw BluetoothOperationTimedOut(deviceIdentifier: deviceIdentifier, operation: operation)
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}
