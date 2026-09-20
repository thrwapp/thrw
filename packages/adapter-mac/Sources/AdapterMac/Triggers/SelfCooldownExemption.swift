import Foundation

extension EventKind {
    /// Whether this trigger is exempt from ``SelfCooldown`` (#212).
    ///
    /// The cooldown exists so thrw does not react to **its own** side
    /// effects: connecting the headset changes this device's audio
    /// routing, which the media monitor would otherwise report as a fresh
    /// trigger (ADR 0010 point 1, #167).
    ///
    /// A `manual_claim` is not a side effect. It is the user saying "put
    /// the headset here", and ADR 0010's own principle is that direct
    /// user action always wins. Suppressing it would mean the button did
    /// nothing for three seconds after any switch - intermittently, and
    /// silently, which is the worst possible behaviour for the control
    /// you reach for *because* the automation got it wrong.
    ///
    /// Every other kind is observed rather than requested, so every other
    /// kind can legitimately be an echo of our own action.
    var bypassesSelfCooldown: Bool {
        self == .manualClaim
    }
}
