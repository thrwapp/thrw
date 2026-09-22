import Foundation

/// Publishes this node's liveness beat so the relay doesn't reap it.
///
/// Deliberately **not** part of ``NodeInterface`` (#142): that protocol is
/// a frozen contract at exactly four methods - `register`, `emitEvent`,
/// `onClaim`, `onRelease` (ADR 0001, AGENTS.md). Adding a fifth would
/// need its own ADR and human review. The heartbeat *topic* and its
/// interval are already specified in architecture.md's topic table, so
/// publishing to it is fulfilling the frozen contract, not changing it -
/// this separate seam is how both can be true at once.
public protocol HeartbeatSink: Sendable {
    func publishHeartbeat() async throws
}

/// architecture.md's "MQTT topic design" table specifies this topic as
/// `QoS 0, ~30s`. `services/relay-hosted`'s `DEFAULT_HEARTBEAT_TIMEOUT_MS`
/// is 90s - deliberately 3x this value, so a couple of missed beats is
/// normal jitter and three in a row is "gone".
///
/// **These two numbers must stay in that 3:1 relationship.** Changing
/// this interval without changing the relay's timeout (or vice versa)
/// silently changes how long a dead node keeps its claim - or, worse,
/// starts reaping live ones. `adapter-android`'s
/// `HeartbeatPublisher.DEFAULT_INTERVAL_MS` is the same constant on the
/// other side of the same contract.
public let defaultHeartbeatInterval: Duration = .seconds(30)

/// Beats once per ``defaultHeartbeatInterval`` until cancelled.
///
/// Why this exists at all: before #142 neither adapter published a
/// heartbeat, while `services/relay-hosted`'s `sweepHeartbeats` reaped
/// any node that hadn't beaten within its timeout - so every real node
/// was dropped ~90s after registering, and (after #130 wired
/// `PriorityEngine.forgetNode` into that same sweep) had a RELEASE
/// published to it, disconnecting the headset mid-call.
public final class HeartbeatPublisher {
    private let sink: HeartbeatSink
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `sleep` is injectable purely so tests don't wait on wall time -
    /// the same reasoning `PriorityEngine`'s injectable `Scheduler` uses
    /// on the TypeScript side. Production callers take the default.
    public init(
        sink: HeartbeatSink,
        interval: Duration = defaultHeartbeatInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sink = sink
        self.interval = interval
        self.sleep = sleep
    }

    /// Beats once, then once per `interval`, until the calling task is
    /// cancelled.
    ///
    /// The first beat is sent *before* the first sleep, so that a caller
    /// starting this right after registration doesn't spend a third of
    /// the relay's 90s budget silent. Note this is only correct because
    /// ``NodeRuntime`` waits for registration to complete before starting
    /// this loop - the relay doesn't subscribe to a node's heartbeat
    /// topic until it has seen that node register, so a beat sent any
    /// earlier is published to nobody.
    ///
    /// ## A failed beat does not end the loop (#236)
    ///
    /// This used to be `try await sink.publishHeartbeat()` directly in the
    /// loop body, so **one** throw ended it permanently. ``NodeRuntime``
    /// catches and logs that, and nothing ever restarts it; `onReconnected`
    /// only re-registers. So a single transient publish failure - an MQTT
    /// drop lasting one beat - silently stopped this node heartbeating for
    /// the rest of the process's life, while it stayed connected and kept
    /// re-registering every 120s.
    ///
    /// That is not a quiet degradation. The relay seeds node liveness from
    /// each registration (`relay-service.ts`'s `handleEvent` ->
    /// `trackHeartbeat`) and reaps at 90s, and reaping drops every signal
    /// the node had via `PriorityEngine.forgetNode`. A node that registers
    /// but never beats therefore takes the headset on every registration
    /// and loses it 90s later, forever. Two such nodes ping-pong: observed
    /// in production for nine and a half hours overnight, ~30 handoffs an
    /// hour, with nobody using either device.
    ///
    /// Retrying is safe: a heartbeat is a bare liveness ping at QoS 0 with
    /// no payload state, so a lost one has no consequence beyond being
    /// lost. The retry cadence is just `interval` - failing still sleeps,
    /// so a broker that is down cannot turn this into a hot loop, and no
    /// backoff is needed on top of an already-30s period.
    ///
    /// Cancellation still ends the loop, and is deliberately re-thrown
    /// rather than swallowed by the `catch` - ``NodeRuntime`` distinguishes
    /// the two, and treating a cancelled task as a publish failure would
    /// log an error on every ordinary app quit.
    public func run() async throws {
        // Logged on transition only, not per beat: a broker that is down
        // for an hour would otherwise write 120 identical lines, and the
        // signal worth having is "when did it break" and "did it come
        // back", not "it is still broken".
        var isFailing = false
        while true {
            try Task.checkCancellation()
            do {
                try await sink.publishHeartbeat()
                if isFailing {
                    isFailing = false
                    logAdapterInfo(category: "HeartbeatPublisher", "heartbeat resumed")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !isFailing {
                    isFailing = true
                    logAdapterError(
                        category: "HeartbeatPublisher",
                        "heartbeat publish failed, retrying every \(interval): \(String(describing: error))"
                    )
                }
            }
            try await sleep(interval)
        }
    }
}
