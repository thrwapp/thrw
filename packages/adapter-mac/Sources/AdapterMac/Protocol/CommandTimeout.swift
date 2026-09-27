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
/// ## Why this is unstructured, and why it has to be (#303)
///
/// This was a `withThrowingTaskGroup` racing `body()` against a sleep,
/// which reads as obviously correct and **cannot time out at all** when
/// the work is stuck in a suspension that does not answer cancellation.
/// A task group is guaranteed empty when it returns, so it awaits every
/// child before propagating anything - including the child that will
/// never finish. The timeout error is produced on schedule and then
/// waits forever behind the thing it was supposed to escape.
///
/// That is not hypothetical. ``IOBluetoothPeripheralGateway/connect``
/// suspends on a `withCheckedThrowingContinuation` resumed only by
/// `IOBluetooth`'s `connectionComplete` callback, and a checked
/// continuation is not cancellation-aware: if that callback never
/// arrives, `cancelAll()` does nothing and the group never returns. On
/// the reference Mac that hung a claim for seventeen minutes with **no
/// `command_outcome` published at all** (ADR 0019 requires one within
/// 8s), and it latched ``RouteTransition``'s counter, because the
/// `defer`s that decrement it belong to frames that never unwound.
///
/// #244's own test missed this for a precise reason worth keeping: its
/// fake blocks on an `AsyncStream`, which *is* cancellation-aware, so
/// `cancelAll()` unsticks it and the group returns. The bound looked
/// bounded in tests and was not in production - see
/// ``FakeBluetoothPeripheralGateway/blockNextConnectUncancellably``,
/// which reproduces the real shape.
///
/// So the race is run over unstructured tasks and a one-shot
/// continuation: whichever of the two finishes first resolves the
/// caller, and the loser is cancelled but never awaited.
///
/// ## What this leaks, deliberately
///
/// A `body()` that neither finishes nor answers cancellation keeps
/// running after this returns - one abandoned task per stuck command.
/// That is not a choice this code can avoid: a continuation nobody
/// resumes can never be reclaimed. The alternative is the current
/// behaviour, where the whole adapter wedges instead, so the trade is
/// not close. It is bounded in practice by how many commands a node
/// receives, and `BluetoothConnectionManager` resolves its own state on
/// the timeout so later claims are still attempted (#244).
func withBluetoothTimeout(
    _ timeout: Duration,
    deviceIdentifier: UUID,
    operation: String,
    _ body: @escaping @Sendable () async throws -> Void
) async throws {
    let outcome = FirstOutcome()

    let work = Task {
        do {
            try await body()
            outcome.finish(.success(()))
        } catch {
            outcome.finish(.failure(error))
        }
    }
    let timer = Task {
        // A cancelled sleep is the ordinary "the work won already" path,
        // not a timeout - so it must not report one.
        guard (try? await Task.sleep(for: timeout)) != nil else { return }
        outcome.finish(
            .failure(BluetoothOperationTimedOut(deviceIdentifier: deviceIdentifier, operation: operation))
        )
    }
    // Cancelling the loser matters even though it is never awaited: a
    // cancellable body (every test fake, and any future gateway that
    // handles cancellation) really does stop here, and the timer task
    // would otherwise sleep out its full window after a fast success.
    defer {
        work.cancel()
        timer.cancel()
    }

    // Unstructured tasks do not inherit cancellation, which is what
    // makes abandoning one possible - and also means this has to
    // propagate cancellation by hand.
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            outcome.attach(continuation)
        }
    } onCancel: {
        outcome.finish(.failure(CancellationError()))
    }
}

/// A one-shot rendezvous: the first of several racers to report wins,
/// and the caller is resumed exactly once however the ordering falls.
///
/// An `NSLock` rather than an actor because ``withBluetoothTimeout``'s
/// `onCancel` handler is synchronous and cannot await one. The stored
/// `pending` result covers the case that made the first version of this
/// flaky by construction: a racer can finish before the caller has
/// attached its continuation, and a signal-only rendezvous would resume
/// nobody.
private final class FirstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pending: Result<Void, Error>?
    private var resolved = false

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let pending, !resolved {
            resolved = true
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        if let continuation {
            resolved = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if pending == nil { pending = result }
        lock.unlock()
    }
}
