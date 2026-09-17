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
public enum Topics {
    public static func events(account: String, node: String) -> String {
        "thrw/\(account)/nodes/\(node)/events"
    }

    public static func commands(account: String, node: String) -> String {
        "thrw/\(account)/commands/\(node)"
    }

    public static func state(account: String) -> String {
        "thrw/\(account)/state"
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
}
