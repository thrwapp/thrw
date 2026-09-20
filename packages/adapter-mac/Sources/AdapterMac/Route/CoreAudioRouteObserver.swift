#if canImport(CoreAudio)

import CoreAudio
import Foundation

/// Real ``AudioRouteObserver``: is the headset the current default output
/// device (#191)?
///
/// `kAudioHardwarePropertyDefaultOutputDevice` is the same property
/// ``CoreAudioPlaybackSource`` already watches to know when the default
/// device changes, so this adds no new platform dependency - only a
/// different question asked of it.
///
/// Not unit-tested: CI has no audio device and no Bluetooth. The decision
/// this makes is ``audioDeviceUID(_:matchesBluetoothAddress:)``, which is
/// a pure function and *is* tested; everything else here is reading two
/// CoreAudio properties.
public struct CoreAudioRouteObserver: AudioRouteObserver {
    /// The headset's Bluetooth address, as provisioning stores it.
    private let headsetAddress: String

    public init(headsetAddress: String) {
        self.headsetAddress = headsetAddress
    }

    public func holdsAudioRoute() -> Bool? {
        guard let device = Self.defaultOutputDevice() else {
            // No default output device at all. That is not "the headset
            // is elsewhere", it is "this machine cannot currently answer",
            // so it must not be reported as a definite `false`.
            return nil
        }
        guard let uid = Self.deviceUID(device) else { return nil }
        return audioDeviceUID(uid, matchesBluetoothAddress: headsetAddress)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }
}

#endif
