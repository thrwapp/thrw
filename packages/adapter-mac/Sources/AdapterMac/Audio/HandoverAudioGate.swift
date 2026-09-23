import Foundation

/// Silences this device's audio across a handover window (ADR 0022).
///
/// A handover takes roughly 4.9s on the reference hardware, and for
/// ~2.7s of it *no device holds the headset* - the old host has released
/// and the new one has not finished connecting (#254, measured).
/// Anything playing during that window comes out of the built-in
/// speakers.
///
/// ## The two calls are not symmetric
///
/// - **On release**: ``silence()`` only. The user has moved to another
///   device; continuing to play here is never what they wanted.
/// - **On claim**: ``silence()`` then ``restore()`` once the command
///   resolves.
///
/// ``restore()`` must run on **every** terminal outcome, not only
/// success. ADR 0019 gives exactly three - succeeded, failed, timed_out
/// - and a user left silenced because a claim failed would be a worse
/// bug than the one this fixes.
///
/// ## Why macOS mutes rather than pauses
///
/// ADR 0022 originally specified pausing on both platforms, and pausing
/// remains the target here. The spike found it needs **Accessibility**:
/// synthesising `NX_KEYTYPE_PLAY` does nothing from an untrusted
/// process, and works once granted. Three things argued against paying
/// that price now, recorded in the ADR's 2026-09-23 amendment:
///
/// 1. Accessibility lets an application control the whole computer - a
///    heavy ask for a menu-bar headset switcher.
/// 2. Media keys are a *toggle*, so on release, where this wants
///    "pause", an already-paused device would start playing.
/// 3. The app is ad-hoc signed, and macOS TCC keys a grant to the code
///    signature - falling back to the cdhash, which changes every build.
///    "Grant once" would be "re-grant after every update".
///
/// Muting needs no permission and has no toggle ambiguity. It is
/// explicitly temporary: #267 switches macOS to pausing once #132
/// (Developer ID signing) makes the grant survive an update, and #265
/// covers the gap in the meantime - a mute, unlike a pause, is invisible
/// to the person it happened to.
public protocol HandoverAudioGate: Sendable {
    /// Silences audio on this device. Safe to call when nothing is
    /// playing, and safe to call twice.
    func silence() async

    /// Undoes ``silence()``. Safe to call without a preceding
    /// ``silence()``, and must not start audio that was not playing.
    func restore() async
}

/// The gate used when none is supplied - does nothing.
///
/// Deliberately a no-op rather than a failure: a node built without a
/// gate should behave exactly as it did before ADR 0022, leaking audio
/// across the window as it always has, rather than refusing to hand over
/// at all.
public struct NoOpHandoverAudioGate: HandoverAudioGate {
    public init() {}
    public func silence() async {}
    public func restore() async {}
}
