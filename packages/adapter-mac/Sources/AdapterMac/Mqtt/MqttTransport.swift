import Foundation

/// The seam between the node interface and whichever MQTT client library
/// is underneath it. Deliberately narrow: publish a payload on a topic
/// at a QoS, subscribe to a topic at a QoS, close. Same shape as
/// `adapter-android/mqtt/MqttTransport.kt`.
///
/// It takes topics and QoS numbers rather than deriving them, so every
/// topic string in this adapter comes from ``Topics`` and every QoS from
/// ``TopicQos`` (the same discipline `packages/relay-core`'s
/// `RelayMqttClient` enforces on the TypeScript side, and
/// `adapter-android`'s own `MqttTransport` enforces on the Kotlin side).
/// Tests fake this protocol; ``MQTTNIOTransport`` is the real
/// implementation.
public protocol MqttTransport: Sendable {
    func publish(topic: String, payload: String, qos: Int, retained: Bool) async throws

    /// A fresh subscription each call - the underlying MQTT `SUBSCRIBE`
    /// happens when this is called (mirroring the Kotlin
    /// `MqttTransport.subscribe`'s cold-`Flow` semantics), not lazily on
    /// first iteration of the returned stream.
    func subscribe(topic: String, qos: Int) -> AsyncStream<String>

    func close() async throws

    /// Registers `handler` to run whenever the transport
    /// **re-establishes** a dropped connection - not on the first
    /// connect (#182).
    ///
    /// The node uses this to re-register: the relay learns of a node only
    /// from a registration and holds that in memory, so a node that
    /// silently reconnects is connected but invisible - #178 by another
    /// route. Reconnect is also when the relay's picture is most likely
    /// stale, and #178 made registration a safe, repeatable statement of
    /// current state rather than an edge.
    func onReconnected(_ handler: @escaping @Sendable () -> Void)
}

extension MqttTransport {
    /// Default no-op, so the fakes in this package's tests and any
    /// transport without a reconnect story need no change.
    public func onReconnected(_ handler: @escaping @Sendable () -> Void) {}
}

extension MqttTransport {
    /// `retained` defaults to `false` - the Swift equivalent of Kotlin's
    /// default parameter, which a protocol requirement itself can't
    /// carry.
    public func publish(topic: String, payload: String, qos: Int) async throws {
        try await publish(topic: topic, payload: payload, qos: qos, retained: false)
    }
}
