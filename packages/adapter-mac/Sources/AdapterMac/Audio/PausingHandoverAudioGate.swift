import Foundation

/// ``HandoverAudioGate`` that **pauses** playback across the handover
/// window, rather than muting it (#267).
///
/// This is what ADR 0022 originally specified for both platforms, and
/// what `adapter-android`'s `MediaSessionHandoverAudioGate` has always
/// done. macOS shipped muting instead, as a deliberate temporary
/// divergence recorded in that ADR's 2026-09-23 amendment. This closes
/// it.
///
/// ## Why muting was the wrong mechanism, in the end
///
/// Not a matter of taste — it failed on two of its three paths, and the
/// evidence arrived from real hardware within hours of shipping:
///
/// - **The release path never worked.** #282 measured the reference
///   AirPods reporting *no main-element volume at all*
///   (`settable: false`). On release the headset is still the default
///   output, so there was nothing the muting gate could set.
/// - **The claim path leaks before it starts.** Audio begins when the
///   user presses play; the claim command arrives roughly a second
///   later. Muting only from then on leaves that second audible.
///
/// The deeper reason is that **a pause is restorative and a mute is
/// lossy**. Pausing gives back exactly what it took: playback resumes
/// where it stopped, so arriving late costs the user nothing. Muting
/// lets audio play on inaudibly — the user loses that content — while
/// the window before it engages is plainly audible anyway.
///
/// ## The toggle problem, which is the whole design here
///
/// The media key is `play/pause`: one key that **starts what is stopped
/// and stops what is playing**. ADR 0022's amendment named this as a
/// reason to avoid the approach, because on the release path, where the
/// gate wants "pause", an already-paused Mac would start *playing*.
///
/// So the key is never fired blind. ``silence()`` fires it only when
/// ``AudioPlaybackState`` says something is actually playing, and
/// ``restore()`` fires it only if this gate is the thing that paused.
/// A state that cannot be read is treated as "do nothing", never as
/// "probably playing".
///
/// ## No persistence, deliberately
///
/// ``MutingHandoverAudioGate`` needed a durable record and startup
/// recovery because a mute that is never undone is invisible and
/// unrecoverable — ADR 0022's amendment made that a *requirement* of
/// choosing to mute. A pause needs none of it: if this process dies
/// mid-window the user sees a paused player and presses play, which is
/// the entire argument for pausing over muting, made concrete. The
/// state here is in-memory and that is the correct trade, not a
/// shortcut.
public actor PausingHandoverAudioGate: HandoverAudioGate {
    /// How this gate is currently suppressing, if it is.
    private enum Suppression {
        /// We pressed play/pause and owe a matching press.
        case paused
        /// Accessibility was missing, so ``fallback`` took the call and
        /// owes the matching restore. Recorded so a grant arriving
        /// mid-window cannot leave a mute un-restored by the wrong
        /// mechanism.
        case delegated
    }

    private let mediaKey: MediaKeySender
    private let playback: AudioPlaybackState
    private let accessibility: AccessibilityAuthorization
    private let fallback: HandoverAudioGate
    private var active: Suppression?

    /// - Parameter fallback: used whenever Accessibility is not granted.
    ///   Supplying ``MutingHandoverAudioGate`` keeps the pre-#267
    ///   behaviour for an un-granted machine — partial suppression
    ///   beats none — while ``NoOpHandoverAudioGate`` opts out entirely.
    public init(
        mediaKey: MediaKeySender,
        playback: AudioPlaybackState,
        accessibility: AccessibilityAuthorization,
        fallback: HandoverAudioGate = NoOpHandoverAudioGate()
    ) {
        self.mediaKey = mediaKey
        self.playback = playback
        self.accessibility = accessibility
        self.fallback = fallback
    }

    public func silence() async {
        // Already suppressing. A release silences without restoring, so
        // the very next claim lands here - and pressing play/pause again
        // would *resume* the audio this gate just stopped.
        guard active == nil else { return }

        // The whole call is delegated, not just this half: mixing
        // mechanisms across one window would mean restoring with the
        // wrong one. Recorded so `restore()` knows which it owes.
        guard accessibility.isTrusted() else {
            await fallback.silence()
            active = .delegated
            return
        }

        // Nothing playing means nothing to pause - and firing the toggle
        // here would *start* playback the user had stopped.
        guard playback.isPlaying() == true else { return }

        mediaKey.sendPlayPause()
        active = .paused
    }

    public func restore() async {
        switch active {
        case .paused:
            mediaKey.sendPlayPause()
            active = nil
        case .delegated:
            await fallback.restore()
            active = nil
        case nil:
            // Never paused, so nothing to resume. Firing the toggle here
            // would start playback that was never ours to start.
            break
        }
    }

    /// #265. A pause is self-evident where a mute is not, so this exists
    /// mainly to answer honestly when the fallback is the one
    /// suppressing — the menu's un-mute item is about a mute, and a
    /// paused player needs no indicator.
    public func isSuppressing() async -> Bool {
        switch active {
        case .paused: return false
        case .delegated: return await fallback.isSuppressing()
        case nil: return false
        }
    }
}
