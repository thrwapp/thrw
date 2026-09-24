import Foundation

/// Sends the system play/pause media key (#267).
///
/// A seam, so ``PausingHandoverAudioGate``'s logic — which is where the
/// toggle problem is actually solved — is testable without synthesising
/// real system events.
public protocol MediaKeySender: Sendable {
    /// Presses and releases `F8` / play-pause, as the keyboard would.
    ///
    /// **This is a toggle, not a pause.** It stops what is playing and
    /// starts what is not, which is why no caller may fire it without
    /// first establishing which of those it wants — see
    /// ``PausingHandoverAudioGate``.
    func sendPlayPause()
}

#if canImport(AppKit)

import AppKit

/// Real ``MediaKeySender``, synthesising `NX_KEYTYPE_PLAY` as a
/// `systemDefined` event and posting it to the HID event tap.
///
/// ## Why this needs Accessibility, and why that is now acceptable
///
/// A synthesised event posted to `.cghidEventTap` is discarded silently
/// from an untrusted process — no error, no delivery. The grant is
/// checked before use by ``AccessibilityAuthorization``, never inferred
/// from the post appearing to succeed, because it always appears to.
///
/// ADR 0022's amendment deferred this on the grounds that macOS keys the
/// TCC grant to the code signature, falling back to the cdhash, which
/// changes on every ad-hoc-signed build — so "grant once" is really
/// "re-grant after every update". That cost is real and has not changed;
/// what changed is the alternative. #282 established that the reference
/// AirPods expose **no settable volume at all**, so muting cannot work
/// on the release path, where the headset is still the default output.
/// A mechanism that fails on two of its three paths is the worse trade,
/// and Tom accepted the re-grant cost explicitly.
///
/// Not unit-tested: synthesising system events in CI would test the
/// window server, not this code. ``PausingHandoverAudioGate`` holds the
/// decisions and is tested against a fake.
public struct CGEventMediaKeySender: MediaKeySender {
    public init() {}

    public func sendPlayPause() {
        post(keyDown: true)
        post(keyDown: false)
    }

    /// `NX_KEYTYPE_PLAY` from IOKit's `ev_keymap.h`, written out rather
    /// than imported: `IOKit.hidsystem`'s Swift overlay does not export
    /// these constants, and one named integer is a smaller liability
    /// than a bridging header for a value that has been 16 since OS X.
    private static let playKey: Int32 = 16

    private func post(keyDown: Bool) {
        // The encoding `systemDefined`/subtype 8 events use: key in the
        // high 16 bits, state in the next 8. `0xA` is down, `0xB` is up,
        // in both `data1` and the modifier flags.
        let state: Int32 = keyDown ? 0xA : 0xB
        let data1 = Int((Self.playKey << 16) | (state << 8))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(state) << 8)

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else {
            logAdapterError(category: "MediaKeySender", "could not construct a media-key event")
            return
        }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}

#endif
