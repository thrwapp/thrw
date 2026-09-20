import Foundation

/// Whether a *given device* currently holds the audio route (#225, ADR
/// 0018 decision 3).
///
/// ``AudioRouteObserver`` answers the same question, but only about the
/// one headset it was built for, and ``BluetoothConnectionManager`` is
/// keyed by device identifier. This protocol is the adapter between the
/// two, and it exists rather than passing an `AudioRouteObserver`
/// straight into the manager because that would silently answer for the
/// wrong device the moment a second one appeared.
///
/// Android reaches the same place by a different route: it hangs
/// `isAudioRouteActive(deviceAddress)` off `BluetoothClassicGateway`,
/// which its connection manager already holds. macOS keeps the CoreAudio
/// read (``AudioRouteObserver``) and the IOBluetooth control
/// (``BluetoothPeripheralGateway``) apart, because on this platform they
/// are genuinely different frameworks reading different things - so the
/// join happens here instead, at the composition root's choosing.
public protocol DeviceAudioRouteSource: Sendable {
    /// `true` if `deviceIdentifier` currently holds the route, `false`
    /// if it definitely does not, and **`nil` if that cannot be
    /// determined** - including when this source knows nothing about
    /// that device.
    ///
    /// `nil` must not be smoothed into `false`. `false` is an assertion
    /// that the device does not hold the route, and
    /// ``BluetoothConnectionManager`` acts on it by overriding its own
    /// cached state; "I cannot tell" is no reason to do that.
    func holdsAudioRoute(deviceIdentifier: UUID) -> Bool?
}

/// A ``DeviceAudioRouteSource`` that answers for exactly one headset,
/// from an ``AudioRouteObserver`` built for it.
///
/// The identity guard is the whole point of the type. A node manages one
/// headset today, so the guard never fires in production - but an
/// observer bound to the AirPods reporting confidently about some other
/// paired device would be a fabricated answer, and the failure would be
/// a silently skipped claim, which is precisely the bug #225 exists to
/// close.
public struct HeadsetAudioRouteSource: DeviceAudioRouteSource {
    private let headsetIdentifier: UUID
    private let observer: AudioRouteObserver

    public init(headsetIdentifier: UUID, observer: AudioRouteObserver) {
        self.headsetIdentifier = headsetIdentifier
        self.observer = observer
    }

    public func holdsAudioRoute(deviceIdentifier: UUID) -> Bool? {
        guard deviceIdentifier == headsetIdentifier else { return nil }
        return observer.holdsAudioRoute()
    }
}
