import CoreAudio
import Foundation

/// Reads and writes the volume of a **named** output device (ADR 0022,
/// corrected by #282).
///
/// A seam so ``MutingHandoverAudioGate``'s logic - which is where the
/// crash-recovery rule lives, and the only part that can be got wrong in
/// an interesting way - is unit-testable without audio hardware. Same
/// split ``BluetoothPeripheralGateway`` and ``RunningApplicationSource``
/// use.
///
/// ## Why every call names a device
///
/// It did not, and that was the bug. The first version resolved
/// `kAudioHardwarePropertyDefaultOutputDevice` separately inside each
/// read and write, which is safe only if the default cannot change
/// between them. During a claim it changes every time: the gate mutes
/// the built-in speakers, the headset finishes connecting and becomes
/// the default, and the restore then writes to the *headset* — leaving
/// the speakers at zero with the record already consumed.
///
/// Addressing a device explicitly makes that impossible to express.
///
/// ## Why a UID rather than an `AudioDeviceID`
///
/// `AudioDeviceID` is an ephemeral handle: not stable across a reboot,
/// nor guaranteed stable across a device disappearing and returning.
/// The record this identifies must survive the process dying
/// mid-handover (ADR 0022's amendment), so it must not be a number that
/// could later name a *different* device — restoring a stranger's
/// volume would be worse than the bug being fixed.
/// `kAudioDevicePropertyDeviceUID` is the stable string Core Audio
/// provides for exactly this.
public protocol SystemOutputVolume: Sendable {
    /// UID of the current default output device, or `nil` if it cannot
    /// be read.
    func defaultOutputUID() -> String?

    /// Current volume of `uid` in 0...1, or `nil` if it cannot be read.
    ///
    /// `nil` is ordinary, not exceptional: **the reference AirPods
    /// report no main-element volume at all** (#282). A device that
    /// cannot be read must never be muted, because it equally cannot be
    /// restored.
    func volume(forUID uid: String) -> Float?

    /// Sets `uid`'s volume. Ignored if the device is gone or has no
    /// settable main-element volume.
    func setVolume(_ volume: Float, forUID uid: String)
}

/// Real ``SystemOutputVolume``, backed by CoreAudio.
///
/// Public API, and no TCC grant of any kind — the reason ADR 0022's
/// amendment chose muting on macOS for now.
///
/// ## What is actually verified, and what was wrong before
///
/// On the reference Mac, `MacBook Air Speakers` reads `0.250` with
/// `settable: true` from an untrusted process. **`Tom's AirPods Pro`
/// reads nothing and is not settable.**
///
/// An earlier version of this comment offered the `0.25` reading as
/// proof the approach worked. It was measured on the speakers while the
/// headset was connected elsewhere, and attributed to the headset
/// (#282). The consequence is real and worth stating plainly: this gate
/// can suppress audio that would come out of the **speakers**, which is
/// the leak worth stopping — and it can do nothing whatsoever on a
/// device like the headset itself.
///
/// Not unit-tested, for the reason every real seam implementation in
/// this package is not: there is no audio hardware in CI.
public struct CoreAudioSystemOutputVolume: SystemOutputVolume {
    public init() {}

    public func defaultOutputUID() -> String? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        return Self.uid(of: device)
    }

    public func volume(forUID uid: String) -> Float? {
        guard let device = Self.device(withUID: uid) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    public func setVolume(_ volume: Float, forUID uid: String) {
        guard let device = Self.device(withUID: uid) else {
            logAdapterError(category: "SystemOutputVolume", "output device \(uid) is gone; not restoring its volume")
            return
        }
        var address = Self.volumeAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            logAdapterError(category: "SystemOutputVolume", "output device \(uid) has no settable volume")
            return
        }
        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            logAdapterError(category: "SystemOutputVolume", "could not set volume on \(uid): OSStatus \(status)")
        }
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

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

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    /// Resolves a UID back to a live device, or `nil` if nothing with
    /// that UID is present.
    ///
    /// The `nil` is what makes a stale record safe: a headset that has
    /// since been unpaired simply cannot be written to, rather than its
    /// old `AudioDeviceID` addressing whatever now occupies that slot.
    private static func device(withUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return nil }

        return ids.first { self.uid(of: $0) == uid }
    }
}
