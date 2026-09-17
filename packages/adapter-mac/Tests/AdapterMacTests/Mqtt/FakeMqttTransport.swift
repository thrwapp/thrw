import Foundation

@testable import AdapterMac

struct PublishedMessage: Equatable {
    let topic: String
    let payload: String
    let qos: Int
    let retained: Bool
}

struct Subscription: Equatable {
    let topic: String
    let qos: Int
}

/// Fakes the ``MqttTransport`` seam - mirrors `adapter-android`'s
/// `AndroidNodeTest.kt`'s `FakeMqttTransport`, and this package's own
/// `FakeBluetoothPeripheralGateway` (plain mutable state, `@unchecked
/// Sendable`, no lock - a test fixture driven sequentially within one
/// `async` test method, never from concurrent tasks). The end-to-end
/// behaviour against a real broker is a separate, not-yet-written
/// integration test (mirroring `adapter-android`'s own
/// `HiveMqttTransportTest` against an embedded broker) - out of scope
/// for #112, which is the node-interface wiring, not transport
/// verification.
///
/// The commands stream is created once, in ``init()``, rather than fresh
/// per ``subscribe(topic:qos:)`` call - this lets a test call
/// ``sendCommand(_:)`` *before* the code under test ever calls
/// `subscribe`, exactly like Kotlin's `Channel(UNLIMITED)` buffers sends
/// regardless of when `.collect` starts. `AsyncStream`'s default
/// buffering policy is `.unbounded`, the same guarantee.
final class FakeMqttTransport: MqttTransport, @unchecked Sendable {
    private(set) var published: [PublishedMessage] = []
    private(set) var subscriptions: [Subscription] = []

    private let commandsStream: AsyncStream<String>
    private let commandsContinuation: AsyncStream<String>.Continuation

    init() {
        var continuation: AsyncStream<String>.Continuation!
        commandsStream = AsyncStream { continuation = $0 }
        commandsContinuation = continuation
    }

    func publish(topic: String, payload: String, qos: Int, retained: Bool) async throws {
        published.append(PublishedMessage(topic: topic, payload: payload, qos: qos, retained: retained))
    }

    func subscribe(topic: String, qos: Int) -> AsyncStream<String> {
        subscriptions.append(Subscription(topic: topic, qos: qos))
        return commandsStream
    }

    func close() async throws {}

    /// Test control: delivers `payload` on the commands stream, as if
    /// the broker had published it.
    func sendCommand(_ payload: String) {
        commandsContinuation.yield(payload)
    }

    /// Test control: ends the commands stream, so `MacNode.listenForCommands`'s
    /// `for await` loop returns instead of suspending forever - the
    /// direct equivalent of Android's `commands.close()`.
    func finishCommands() {
        commandsContinuation.finish()
    }
}
