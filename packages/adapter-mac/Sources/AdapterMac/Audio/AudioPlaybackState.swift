import Foundation

/// Whether this Mac is playing audio **right now** (#267).
///
/// A point query, where ``AudioPlaybackSource`` is a stream of
/// transitions. ``MediaTriggerMonitor`` wants the edges; the handover
/// gate wants the level, because it has to answer one question at one
/// instant: *is there anything here to pause?*
public protocol AudioPlaybackState: Sendable {
    /// `true` if something is using the default output device, `false`
    /// if nothing is, `nil` if it cannot be determined.
    ///
    /// The `nil` is load-bearing. The media key is a **toggle**, so
    /// firing it without knowing the current state can start playback
    /// that was deliberately stopped — the exact failure ADR 0022's
    /// amendment named when it rejected this approach. A gate that
    /// cannot read the state must do nothing rather than guess.
    func isPlaying() -> Bool?
}

#if canImport(CoreAudio)

import CoreAudio

/// Real ``AudioPlaybackState``, reading
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default output
/// device — the same property ``CoreAudioPlaybackSource`` listens to for
/// #166's media trigger, queried rather than observed.
///
/// Public API, no TCC grant. It reports *any* process's use of the
/// device, not only our own, which is what makes it a usable proxy for
/// "is the user listening to something".
///
/// Not unit-tested: there is no audio hardware in CI.
public struct CoreAudioPlaybackState: AudioPlaybackState {
    public init() {}

    public func isPlaying() -> Bool? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return status == noErr ? running != 0 : nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : nil
    }
}

#endif
