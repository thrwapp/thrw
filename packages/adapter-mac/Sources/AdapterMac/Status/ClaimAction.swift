import Foundation

/// What the menu's claim item should say and whether tapping it does
/// anything (#234).
///
/// A value type with a pure constructor, for the same reason
/// ``nodeStatus(isConnected:holdsRoute:)`` is one: the precedence between
/// the inputs is the entire decision here, it is easy to get subtly
/// wrong, and it is untestable if it lives inside an `NSMenuItem`.
public struct ClaimAction: Equatable, Sendable {
    public let title: String

    /// `false` renders a greyed-out readout rather than a control.
    public let isEnabled: Bool

    public init(title: String, isEnabled: Bool) {
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// Derives the claim item from what this node knows.
///
/// ## The rule, and the bug it replaces
///
/// Before #234 the title came from ``ManualClaim/isHeld()`` alone, which
/// records only whether the user tapped Claim *on this device*. A Mac
/// holding the headset because Spotify was playing still offered "Claim
/// Headset" — the symptom the issue was filed for.
///
/// The fix is not "use the holder instead"; it is to notice the menu item
/// is answering two different questions and to let it answer only the one
/// it can act on:
///
/// 1. **A manual claim is held** → "Release Headset", enabled. Tapping
///    ends it. True regardless of `holdsClaim`, because a claim that has
///    been published but not yet granted is still the user's to cancel.
/// 2. **This node holds the headset, without a manual claim** → a
///    disabled readout naming why. Tapping *cannot* release it: a node
///    can only end its own triggers, and the hold comes from `media`,
///    `voip` or `call`, which end when the underlying activity does.
///    Offering "Release Headset" here would be a control that visibly
///    does nothing; offering "Claim Headset" is the original bug.
/// 3. **Otherwise** → "Claim Headset", enabled.
///
/// Case 3 deliberately also covers `holdsClaim == nil` — the relay has
/// not told us. Claiming is always a safe, meaningful action, so an
/// unknown holder degrades to the useful control rather than to a
/// readout that might be wrong.
///
/// `because` is the trigger that started most recently, not the
/// highest-ranked one: adapters do not rank triggers (architecture.md
/// puts priority rules server-side, "never duplicated in adapters"), so
/// this reads insertion order and nothing else.
public func claimAction(
    holdsClaim: Bool?,
    manualClaimHeld: Bool,
    because: EventKind? = nil
) -> ClaimAction {
    if manualClaimHeld {
        return ClaimAction(title: "Release Headset", isEnabled: true)
    }
    if holdsClaim == true {
        return ClaimAction(title: holdingTitle(because: because), isEnabled: false)
    }
    return ClaimAction(title: "Claim Headset", isEnabled: true)
}

/// Present tense and specific, because the point of this line is to
/// answer "why is the headset here, and why can't I move it from this
/// menu?" in one glance.
private func holdingTitle(because: EventKind?) -> String {
    switch because {
    case .call: return "Holding \u{2014} on a call"
    case .voip: return "Holding \u{2014} in a VoIP call"
    case .media: return "Holding \u{2014} playing media"
    // A manual claim is case 1 above and never reaches here. `nil` is a
    // real state: the relay can make this node holder with no local
    // trigger active at all - it is the only node, say - and inventing a
    // reason would be worse than omitting one.
    case .manualClaim, .none: return "Holding headset"
    }
}
