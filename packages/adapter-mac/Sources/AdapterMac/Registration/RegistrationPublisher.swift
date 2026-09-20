import Foundation

/// How often a node re-announces itself to the relay (#178).
///
/// Two minutes: the worst-case window in which a relay that lost its
/// state is blind to a node that is running but not currently emitting
/// anything.
///
/// Deliberately much slower than ``defaultHeartbeatInterval``. The
/// heartbeat answers "are you still there", which the relay needs
/// promptly so it doesn't reap a live node; this answers "here is
/// everything about me", which only matters after the rare event of the
/// relay losing its picture. `adapter-android`'s
/// `RegistrationPublisher.DEFAULT_INTERVAL_MS` is the same constant on
/// the other side of the same behaviour.
public let defaultRegistrationInterval: Duration = .seconds(120)

/// Re-sends this node's registration periodically, so a relay that lost
/// its picture of the system gets it back (#178).
///
/// The relay learns of a node **only** from a registration message, and
/// holds that entirely in memory. So a relay restart - or merely its MQTT
/// connection dropping and reconnecting, which is how this was found -
/// leaves every already-running node invisible to it: they keep
/// heartbeating into a void and are never arbitrated again. Before this,
/// the only cure was restarting each adapter by hand.
///
/// Each registration carries the node's currently-active triggers
/// (`RegistrationPayload.activeEvents`), so the relay reconciles to the
/// truth rather than inferring it from edges it may have missed. That is
/// what makes re-registering safe to repeat: it is a statement of current
/// state, not an event.
///
/// Unlike ``HeartbeatPublisher``, this **sleeps before its first send**,
/// because ``NodeRuntime`` has already registered once by the time this
/// starts - sending again immediately would be pure noise.
public final class RegistrationPublisher {
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `sleep` is injectable purely so tests don't wait on wall time -
    /// the same seam ``HeartbeatPublisher`` uses.
    public init(
        interval: Duration = defaultRegistrationInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.interval = interval
        self.sleep = sleep
    }

    /// Re-registers once per `interval` until the calling task is
    /// cancelled.
    public func run(register: @Sendable () async throws -> Void) async throws {
        while !Task.isCancelled {
            try await sleep(interval)
            try await register()
        }
    }
}
