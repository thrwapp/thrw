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
}

extension MqttTransport {
    /// `retained` defaults to `false` - the Swift equivalent of Kotlin's
    /// default parameter, which a protocol requirement itself can't
    /// carry.
    public func publish(topic: String, payload: String, qos: Int) async throws {
        try await publish(topic: topic, payload: payload, qos: qos, retained: false)
    }
}
