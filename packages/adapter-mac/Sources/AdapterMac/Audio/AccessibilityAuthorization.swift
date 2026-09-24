import Foundation

/// Whether this process may synthesise system events (#267).
///
/// A seam, because the answer is a property of the machine and the
/// build's code signature, and ``PausingHandoverAudioGate`` has to
/// behave differently on each answer — which is exactly the branch a
/// test needs to drive.
public protocol AccessibilityAuthorization: Sendable {
    /// `true` when the user has granted this build Accessibility.
    ///
    /// Asked **before every use**, not cached at launch. The grant can
    /// be given or revoked in System Settings while the app runs, and a
    /// cached `false` would leave a user who has just granted it
    /// wondering why nothing changed until they relaunched.
    func isTrusted() -> Bool
}

#if canImport(ApplicationServices)

import ApplicationServices

/// Real ``AccessibilityAuthorization``, backed by `AXIsProcessTrusted()`.
///
/// Deliberately the non-prompting call. `AXIsProcessTrustedWithOptions`
/// can raise the system prompt, and raising it from inside a handover —
/// a moment the user did not initiate and is not looking at — would put
/// a permissions dialog on screen in the middle of a phone call. Asking
/// belongs to a deliberate, user-initiated moment; this only ever reads.
///
/// Not unit-tested: it reports the state of the machine, which is not
/// something CI can arrange.
public struct AXAccessibilityAuthorization: AccessibilityAuthorization {
    public init() {}

    public func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}

#endif
