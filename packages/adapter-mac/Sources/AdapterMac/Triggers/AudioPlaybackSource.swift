import Foundation

/// Whether this Mac is currently playing audio.
///
/// Pure Swift, so ``MediaTriggerMonitor`` is testable without CoreAudio -
/// the same split ``RunningApplicationSource`` uses for `NSWorkspace`.
public enum AudioPlaybackEvent: Equatable, Sendable {
    /// Something started using the default output device.
    case started
    /// Nothing is using the default output device any more.
    case stopped
}

/// Where playback state comes from. Faked in tests; the real
/// implementation sits behind CoreAudio's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere`.
public protocol AudioPlaybackSource: Sendable {
    func events() -> AsyncStream<AudioPlaybackEvent>
}
