import Foundation

/// Whether this node currently holds the audio route for its headset
/// (#191, ADR 0018 decisions 2 and 3).
///
/// ## The route, not the Bluetooth link
///
/// This is the distinction the whole mechanism rests on, so it is stated
/// where an implementer will trip over it. **Multipoint headsets hold
/// links to several hosts at once.** Measured on the reference hardware
/// with the *phone* holding the route, the Mac simultaneously reported
/// the AirPods as `Connected` over Bluetooth while its default output
/// device was `MacBook Air Speakers`.
///
/// So "am I connected to the headset" answers *yes on both devices* and
/// is useless as a holder signal - a relay reconciling against it sees
/// two holders and issues corrective commands forever. The signal is the
/// **audio route**: on macOS, whether the headset is the current default
/// output device.
///
/// See `docs/testing/compatibility-matrix.md` for the measurement.
public protocol AudioRouteObserver: Sendable {
    /// `true` if this device currently holds the route, `false` if it
    /// definitely does not, and **`nil` if that cannot be determined**.
    ///
    /// `nil` is not a failure to be smoothed over into `false`: the relay
    /// treats an absent observation as "no information" and leaves its
    /// own record alone, whereas `false` is an assertion that this node
    /// does *not* hold the headset and is grounds for corrective action.
    /// Guessing `false` when the truth is unknown would hand the relay a
    /// fabricated disagreement.
    func holdsAudioRoute() -> Bool?
}

/// Decides whether a CoreAudio device UID refers to a given Bluetooth
/// headset.
///
/// Split out as a pure function, and tested as one, because it is the
/// only part of ``CoreAudioRouteObserver`` that encodes an assumption
/// about a string format Apple does not document. Isolating it means the
/// assumption can be corrected in one obvious place, and that a
/// correction is a test change rather than an archaeology exercise.
///
/// macOS spells a Bluetooth device's `kAudioDevicePropertyDeviceUID`
/// using its MAC address, but the separator and case vary by
/// macOS version and device, and the UID often carries a suffix
/// (`:output`, `-output`). So the comparison normalises both sides down
/// to hex digits rather than matching a literal spelling: `74-15-F5-12-2A-21`,
/// `74:15:f5:12:2a:21` and `7415F5122A21` all compare equal.
public func audioDeviceUID(_ uid: String, matchesBluetoothAddress address: String) -> Bool {
    let hexOnly: (String) -> String = { s in
        s.lowercased().filter { $0.isHexDigit }
    }
    let target = hexOnly(address)
    // A 6-byte MAC is 12 hex digits. Anything shorter is not an address
    // and must not be allowed to match loosely.
    guard target.count == 12 else { return false }
    return hexOnly(uid).contains(target)
}
