import CoreAudio
import Foundation

/// Reads and writes the default output device's volume (ADR 0022).
///
/// A seam so ``MutingHandoverAudioGate``'s logic - which is where the
/// crash-recovery rule lives, and the only part that can be got wrong in
/// an interesting way - is unit-testable without audio hardware. Same
/// split ``BluetoothPeripheralGateway`` and ``RunningApplicationSource``
/// use.
public protocol SystemOutputVolume: Sendable {
    /// Current volume in 0...1, or `nil` if it cannot be read.
    ///
    /// `nil` matters: a device that exposes volume per-channel rather
    /// than on the main element reads as unavailable here, and
    /// ``MutingHandoverAudioGate`` must not treat that as "volume is 0"
    /// and then "restore" a device to silence.
    func current() -> Float?

    /// Sets the volume. Ignored if the device has no settable volume.
    func set(_ volume: Float)
}

/// Real ``SystemOutputVolume``, backed by CoreAudio.
///
/// Public API, and - unlike pausing - **no TCC grant of any kind**,
/// which is the whole reason ADR 0022's amendment chose muting on macOS
/// for now. Verified on the reference Mac reading `0.25` with
/// `settable: true` from an untrusted process.
///
/// Not unit-tested, for the reason every real seam implementation in
/// this package is not: there is no audio hardware in CI.
public struct CoreAudioSystemOutputVolume: SystemOutputVolume {
    public init() {}

    public func current() -> Float? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    public func set(_ volume: Float) {
        guard let device = Self.defaultOutputDevice() else { return }
        var address = Self.volumeAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return
        }
        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            logAdapterError(category: "SystemOutputVolume", "could not set output volume: OSStatus \(status)")
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
}
