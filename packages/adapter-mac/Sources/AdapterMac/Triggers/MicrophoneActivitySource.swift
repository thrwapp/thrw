import Foundation

/// Whether *anything* on this Mac currently has the microphone open
/// (#247).
///
/// The second signal the VoIP trigger needs. On its own, "a known VoIP
/// app is running" is far too coarse: leaving Slack or WhatsApp open all
/// day pinned the headset to the Mac indefinitely, outranking deliberate
/// playback on every other device, because `voip` sits above `media` in
/// `PRIORITY_ORDER`. A VoIP app being open is not a call.
///
/// ## This contradicts what the code used to say
///
/// ``VoipTriggerMonitor``'s kdoc asserted that "not even 'is the
/// microphone in use by another app' is exposed to third parties
/// (confirmed while researching #127)". That is **wrong**.
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input
/// device reports exactly this, it is public CoreAudio, and it needs no
/// TCC grant of any kind.
///
/// Verified on the reference Mac: the property read cleanly from an
/// untrusted process and returned `false` while idle, then `true` with a
/// call live. What #127 actually tested is unknown - possibly a
/// different API - but the claim as written had been shaping decisions,
/// so it is corrected here and at its source rather than left to mislead
/// the next person.
///
/// Modeled on ``RunningApplicationSource``: the real implementation
/// talks to CoreAudio and is not unit-testable, so
/// ``VoipTriggerMonitor``'s tests fake this protocol directly.
public protocol MicrophoneActivitySource: Sendable {
    /// Emits whenever the microphone-in-use state changes.
    ///
    /// **Must emit the current value first**, before any change, for the
    /// same reason ``RunningApplicationSource`` replays already-running
    /// apps: a monitor that starts while a call is already in progress
    /// has to know that, and making every fake in every test reproduce
    /// the replay is worse than making the one real implementation do it.
    func activity() -> AsyncStream<Bool>
}
