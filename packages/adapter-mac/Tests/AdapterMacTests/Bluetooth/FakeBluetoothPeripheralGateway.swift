import Foundation

@testable import AdapterMac

/// Fakes the ``BluetoothPeripheralGateway`` boundary instead of mocking
/// the Bluetooth framework's own classes directly — mirrors
/// `packages/adapter-android`'s `FakeBluetoothClassicGateway`.
final class FakeBluetoothPeripheralGateway: BluetoothPeripheralGateway, @unchecked Sendable {
    private(set) var connectCalls: [UUID] = []
    private(set) var disconnectCalls: [UUID] = []
    var failNextConnect = false
    var failNextDisconnect = false

    /// #225. Holds the next `connect` open so a test can observe the
    /// manager while a connection is genuinely in flight - the only way
    /// to reach the `.connecting` branch through the public API, since
    /// the actor serializes everything else.
    ///
    /// **This block answers cancellation**, because it waits on an
    /// `AsyncStream`. That is convenient and it is also why #244's bound
    /// looked bounded when it was not - see
    /// ``blockNextConnectUncancellably``.
    var blockNextConnect = false

    /// #303. Holds the next `connect` open in a suspension that does
    /// **not** answer cancellation, which is the shape production
    /// actually has and the one no test had.
    ///
    /// ``IOBluetoothPeripheralGateway/connect`` suspends on a
    /// `withCheckedThrowingContinuation` resumed only by `IOBluetooth`'s
    /// `connectionComplete` callback. A checked continuation is not
    /// cancellation-aware, so if that callback never arrives the task
    /// cannot be cancelled out of it - and a `withThrowingTaskGroup`
    /// timeout, which must await every child before returning, never
    /// returns at all. That is the seventeen-minute wedge in #303: no
    /// `command_outcome` published, and ``RouteTransition``'s counter
    /// latched by `defer`s belonging to frames that never unwound.
    ///
    /// `blockNextConnect` above cannot express that, because cancelling
    /// its `AsyncStream` wait works.
    var blockNextConnectUncancellably = false

    /// The release-side equivalent. `disconnect` was not bounded at all
    /// before #303, and ADR 0002's sequential handoff means a stuck
    /// release strands the claim queued behind it.
    var blockNextDisconnectUncancellably = false

    /// Continuations for the blocks above, held rather than dropped so
    /// the runtime does not report them as leaked. Nothing ever resumes
    /// them - that is the point.
    private var neverResumed: [CheckedContinuation<Void, Never>] = []

    // Two one-shot signals, each an `AsyncStream` rather than a
    // `CheckedContinuation`. That is the whole point: a continuation
    // only *signals*, so whichever side arrives first waits for a
    // partner that may already have gone. The first version of this
    // deadlocked roughly half the time - `connect` reached the signal
    // before the test reached the wait, resumed nobody, and both sides
    // waited forever. An `AsyncStream` buffers, so the handshake works
    // in either order and the test cannot be flaky.
    private let started = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    func connect(deviceIdentifier: UUID) async throws {
        connectCalls.append(deviceIdentifier)
        if blockNextConnectUncancellably {
            blockNextConnectUncancellably = false
            started.continuation.yield(())
            await hangForever()
        }
        if blockNextConnect {
            blockNextConnect = false
            started.continuation.yield(())
            for await _ in release.stream { break }
        }
        if failNextConnect {
            failNextConnect = false
            throw FakeGatewayError.simulatedFailure
        }
    }

    /// Suspends until a blocked `connect` has actually entered the
    /// gateway. Sleeping instead would be flaky on a loaded machine;
    /// this is exact.
    func waitUntilConnectStarted() async {
        for await _ in started.stream { break }
    }

    func releaseBlockedConnect() {
        release.continuation.yield(())
    }

    /// Suspends forever, and cannot be cancelled out of.
    private func hangForever() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            neverResumed.append(continuation)
        }
    }

    func disconnect(deviceIdentifier: UUID) async throws {
        disconnectCalls.append(deviceIdentifier)
        if blockNextDisconnectUncancellably {
            blockNextDisconnectUncancellably = false
            started.continuation.yield(())
            await hangForever()
        }
        if failNextDisconnect {
            failNextDisconnect = false
            throw FakeGatewayError.simulatedFailure
        }
    }
}

enum FakeGatewayError: Error, Equatable {
    case simulatedFailure
}
