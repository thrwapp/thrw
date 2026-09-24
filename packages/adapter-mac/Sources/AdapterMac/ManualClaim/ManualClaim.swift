import Foundation

/// The user's own "put the headset here" (#212).
///
/// `manual_claim` sits second in `PRIORITY_ORDER` — below a call, above
/// VoIP and media — and until now nothing emitted it. ADR 0010's
/// principle is that direct user action always wins; this is what makes
/// that true rather than aspirational.
///
/// ## Why it is a toggle, and why it persists
///
/// The obvious design — emit the event, let the relay claim, then end it
/// immediately — does not work, and the failure is quiet enough to be
/// worth recording.
///
/// Ending the event makes the engine recompute the holder from whatever
/// is *still* active. If the Mac is playing media and you manual-claim on
/// the phone, the phone wins on rank, then ends its event, and
/// `computeActiveHolder` hands the headset straight back to the Mac's
/// still-active `media`. The user's action would be undone within a
/// second.
///
/// So the claim persists until it is released, until another node
/// manual-claims (both have it active, and most-recently-started wins,
/// which is the right answer), or until a call outranks it. Media
/// elsewhere deliberately cannot take it back — that is the point of
/// having the control at all.
///
/// **"Until a call outranks it" means ended, not suspended** (#234
/// criterion 5). When the relay releases this node, the claim is over:
/// the headset does not return here when the call finishes, and
/// `MacNode.onRelease()` publishes the end so the relay agrees. The
/// alternative — resuming afterwards — was rejected because a headset
/// that silently reappears on a device minutes after an unrelated call
/// ended is indistinguishable, from the user's side, from the
/// oscillation bugs (#236, #251) this project spent weeks removing.
///
/// Because it persists, the surface has to be a toggle: a claim you
/// cannot see and cannot release is worse than none.
public final class ManualClaim: @unchecked Sendable {
    private let node: EventLifecycle

    public init(node: EventLifecycle) {
        self.node = node
    }

    /// Whether this node is currently holding a manual claim.
    ///
    /// ## Why this is no longer a local boolean (#234)
    ///
    /// It used to be, and that boolean was written in exactly one place
    /// — ``toggle()``. So it recorded *"did the user tap Claim on this
    /// device?"* and nothing else, and it went stale in both directions:
    ///
    /// - A relay-issued RELEASE dropped the headset and never touched
    ///   it, so the menu went on offering "Release Headset" for a claim
    ///   that no longer existed on either side.
    /// - A restart reset it to `false` while the relay might still have
    ///   this node as holder. The Mac relaunches at every login (#144),
    ///   so that was routine rather than exotic.
    ///
    /// The node already tracks this exact fact for a different consumer:
    /// `activeEvents`, which every registration carries so the relay can
    /// reconcile (#178). Deriving from it **removes** the second copy
    /// rather than adding code to keep two copies in step, which is what
    /// stops the same class of staleness coming back in a new form.
    public func isHeld() -> Bool {
        node.isEventActive(.manualClaim)
    }

    /// Claims if not held, releases if held. Returns the new state.
    ///
    /// State still changes only after a successful publish, because
    /// `emitEvent` inserts into the node's active set after its own
    /// publish returns. If the relay cannot be reached the menu keeps
    /// showing the truth rather than a state the relay never heard
    /// about — and the next tap retries rather than toggling into a lie.
    ///
    /// `endEvent` is the deliberate exception: it forgets locally
    /// *before* publishing (#183), so a trigger that really has ended
    /// cannot be stranded as permanently active by one failed publish.
    @discardableResult
    public func toggle() async throws -> Bool {
        let wantToHold = !isHeld()
        if wantToHold {
            try await node.emitEvent(type: .manualClaim, priority: unrankedPriority)
        } else {
            try await node.endEvent(type: .manualClaim)
        }
        return wantToHold
    }
}
