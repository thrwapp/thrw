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

    /// Set by the node under test; fired by ``simulateReconnect()``.
    private var reconnectedHandler: (@Sendable () -> Void)?

    /// #234. Defaults to `true`, matching ``MqttTransport``'s own default
    /// so every existing test is unaffected; set `false` to check that a
    /// node stops presenting relay state it can no longer verify.
    var connected = true

    func isConnected() -> Bool { connected }

    func onReconnected(_ handler: @escaping @Sendable () -> Void) {
        reconnectedHandler = handler
    }

    /// Stands in for the transport re-establishing a dropped connection.
    func simulateReconnect() { reconnectedHandler?() }

    private let commandsStream: AsyncStream<String>
    private let commandsContinuation: AsyncStream<String>.Continuation
    private let stateStream: AsyncStream<String>
    private let stateContinuation: AsyncStream<String>.Continuation

    init() {
        var continuation: AsyncStream<String>.Continuation!
        commandsStream = AsyncStream { continuation = $0 }
        commandsContinuation = continuation
        var stateCont: AsyncStream<String>.Continuation!
        stateStream = AsyncStream { stateCont = $0 }
        stateContinuation = stateCont
    }

    /// #206. Makes every publish throw, so a test can prove that a lost
    /// outcome report does not take the command loop down with it.
    var failPublishes = false

    struct PublishFailed: Error {}

    func publish(topic: String, payload: String, qos: Int, retained: Bool) async throws {
        if failPublishes { throw PublishFailed() }
        published.append(PublishedMessage(topic: topic, payload: payload, qos: qos, retained: retained))
    }

    /// One stream per *kind* of subscription, routed by topic shape.
    ///
    /// This used to return a single shared stream for every topic, which
    /// worked only while the node subscribed to exactly one. It stops
    /// working the moment there are two: several consumers of one
    /// `AsyncStream` **split** its elements between them rather than each
    /// receiving all of them, so when #234 added the state subscription
    /// the state listener silently ate commands and
    /// `listenForCommands`'s tests timed out waiting for a release that
    /// had been delivered to the wrong reader.
    ///
    /// Routed by shape rather than by exact string because this fixture
    /// is shared by tests that build their topics from different
    /// account/node constants.
    func subscribe(topic: String, qos: Int) -> AsyncStream<String> {
        subscriptions.append(Subscription(topic: topic, qos: qos))
        return topic.contains("/state/") ? stateStream : commandsStream
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

    /// Test control: delivers `payload` on the retained state topic, as
    /// if the broker had replayed or published it (#234).
    func sendState(_ payload: String) {
        stateContinuation.yield(payload)
    }

    /// The state-topic partner of ``finishCommands()``, so
    /// `MacNode.listenForState`'s loop can return in a test that awaits
    /// it directly.
    func finishState() {
        stateContinuation.finish()
    }
}
