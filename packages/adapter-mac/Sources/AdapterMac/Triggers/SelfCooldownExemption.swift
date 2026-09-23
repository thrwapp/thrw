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
    /// A `call` is exempt too, since #251 lengthened the window to 6s.
    ///
    /// Without this, a genuine incoming call within 6 seconds of a
    /// switch would be dropped - and a call is the signal this product
    /// can least afford to miss, being first in `PRIORITY_ORDER`. At 3s
    /// that was a narrow enough gap to live with; at 6s it is not.
    ///
    /// Safe on principle, not merely convenient. The cooldown exists
    /// because *connecting the headset changes audio routing*, which
    /// route-derived triggers misread. macOS's call signal is
    /// running-application detection and Android's is
    /// `TelephonyCallback` - neither is route-derived, so a real call
    /// cannot be an echo of our own action, and there is nothing here
    /// for the cooldown to protect against.
    ///
    /// `voip` and `media` are deliberately **not** exempt: both derive
    /// from audio state and so can genuinely echo our own route change.
    /// `media` is exactly what was chattering in #251.
    var bypassesSelfCooldown: Bool {
        self == .manualClaim || self == .call
    }
}
