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
    var blockNextConnect = false

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

    func disconnect(deviceIdentifier: UUID) async throws {
        disconnectCalls.append(deviceIdentifier)
        if failNextDisconnect {
            failNextDisconnect = false
            throw FakeGatewayError.simulatedFailure
        }
    }
}

enum FakeGatewayError: Error, Equatable {
    case simulatedFailure
}
