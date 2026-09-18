import Foundation

@testable import AdapterMac

/// Fakes the ``RunningApplicationSource`` boundary instead of driving
/// real `NSWorkspace` notifications - mirrors this package's other fakes
/// (`FakeBluetoothPeripheralGateway`, `FakeMqttTransport`) and
/// `adapter-android`'s `FakeNotificationSource`-equivalent fixtures in
/// `AndroidNodeTest.kt`.
final class FakeRunningApplicationSource: RunningApplicationSource, @unchecked Sendable {
    private let stream: AsyncStream<RunningApplicationEvent>
    private let continuation: AsyncStream<RunningApplicationEvent>.Continuation

    init() {
        var continuation: AsyncStream<RunningApplicationEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func events() -> AsyncStream<RunningApplicationEvent> {
        stream
    }

    /// Test control: delivers `event` as if `NSWorkspace` had reported it.
    func send(_ event: RunningApplicationEvent) {
        continuation.yield(event)
    }

    /// Test control: ends the stream, so `VoipTriggerMonitor.run`'s
    /// `for await` loop returns instead of suspending forever.
    func finish() {
        continuation.finish()
    }
}
