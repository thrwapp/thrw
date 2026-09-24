import Foundation

/// Swift mirror of `packages/protocol/src/index.ts`'s MQTT topic builders
/// - see docs/spec/architecture.md, "MQTT topic design". Same shape as
/// `adapter-android/protocol/Topics.kt`.
///
/// The topic structure itself is a frozen contract (AGENTS.md, ADR 0001);
/// changing the string shapes below requires a new ADR and human review.
/// These are re-implemented rather than imported because the TypeScript
/// package can't be consumed from Swift - so the *only* discipline that
/// keeps the two in sync is that every publish/subscribe in this adapter
/// goes through this type, never a literal topic string at the call site.
/// ADR 0015's resource types. Mirrors `@thrw/protocol`'s `ResourceType`;
/// the wire spellings are pinned by `packages/protocol/fixtures/topics.json`,
/// which this package's own tests assert against.
public enum ResourceType: String, Codable, Sendable {
    case audio
    case hid
}

public enum Topics {
    public static func events(account: String, node: String, resource: ResourceType) -> String {
        "thrw/\(account)/nodes/\(node)/\(resource.rawValue)/events"
    }

    public static func commands(account: String, node: String, resource: ResourceType) -> String {
        "thrw/\(account)/commands/\(node)/\(resource.rawValue)"
    }

    public static func state(account: String, resource: ResourceType) -> String {
        "thrw/\(account)/state/\(resource.rawValue)"
    }

    public static func heartbeat(account: String, node: String) -> String {
        "thrw/\(account)/nodes/\(node)/heartbeat"
    }
}

/// Swift mirror of `packages/protocol`'s `TopicQos` constant: events QoS
/// 1, commands QoS 1, state retained, heartbeat QoS 0. Same frozen-
/// contract caveat as `Topics` - these values come from
/// architecture.md's "MQTT topic design" section and ADR 0001, not from
/// this adapter.
public enum TopicQos {
    public static let eventsQos = 1
    public static let commandsQos = 1
    public static let stateRetained = true
    public static let heartbeatQos = 0

    /// The QoS this adapter *subscribes* to the state topic at (#234).
    ///
    /// Not a mirror of anything, because there is nothing to mirror:
    /// `packages/protocol`'s `TopicQos.state` specifies only
    /// `{ retained: true }`, and `relay-core`'s `publishState` passes no
    /// QoS, so the relay publishes at 0. A subscription is delivered at
    /// the lower of the two levels, so asking for 1 here would buy
    /// nothing while implying a guarantee the publisher does not make.
    ///
    /// Losing an update is tolerable on this topic in a way it would not
    /// be on commands: the value is retained, so a reconnecting
    /// subscriber is re-sent the current holder immediately, and the
    /// menu reads the latest value on open rather than accumulating
    /// edges.
    ///
    /// If `packages/protocol` ever pins a QoS for state, this becomes a
    /// mirror of it and stops being a local decision.
    public static let stateSubscribeQos = 0
}
