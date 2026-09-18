import Foundation

/// Whether this app is set to start itself at login (#144).
///
/// Mirrors the four cases `SMAppService.Status` reports, spelled out here
/// rather than re-exported so this rule stays testable without
/// `ServiceManagement` (which, like AppKit, doesn't exist on Linux).
public enum LoginItemState: Equatable, Sendable {
    /// Registered and will launch at login.
    case enabled
    /// Not registered - the normal state before the user opts in.
    case notRegistered
    /// Registered, but the user has to approve it in System Settings
    /// before macOS will honour it. A real state, not an error: macOS
    /// reports this when login items are added while the app is
    /// unapproved, and the app cannot resolve it itself.
    case requiresApproval
    /// macOS has no record of this bundle as a login item.
    ///
    /// **This is the normal state for an app that has never registered**,
    /// not an error - verified by running a real unsigned bundle: it
    /// reported `notFound` before its first `register()`, `enabled`
    /// after, and `notRegistered` after a subsequent `unregister()`. So
    /// `notFound` means "never registered" and `notRegistered` means
    /// "registered at some point, currently off"; both are simply "off"
    /// as far as the user is concerned.
    case notFound
}

/// The seam ``AppDelegate`` depends on, so the menu item's behaviour can
/// be exercised against a fake. The real implementation talks to
/// `SMAppService`, which can't run in a unit test - it mutates real
/// system state and needs a real app bundle.
public protocol LoginItemController: Sendable {
    func currentState() -> LoginItemState
    func register() throws
    func unregister() throws
}

/// Decisions the menu item renders, kept separate from both the AppKit
/// glue and the `SMAppService` call so they can be tested.
public enum LoginItem {
    /// Whether the toggle shows a checkmark.
    ///
    /// `requiresApproval` counts as **on**: the user has opted in and the
    /// app is registered; what's outstanding is a system approval the app
    /// can't perform. Showing it unchecked would invite them to click
    /// again, which does nothing useful.
    public static func isOn(_ state: LoginItemState) -> Bool {
        switch state {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        }
    }

    /// What clicking the toggle should do next, given where it is now.
    ///
    /// Derived from the *current system state* rather than a remembered
    /// flag, because the user can revoke a login item in System Settings
    /// without telling the app (#144 acceptance criterion 3).
    public static func action(for state: LoginItemState) -> LoginItemAction {
        isOn(state) ? .unregister : .register
    }

    /// Human-readable status, or `nil` when the plain checkmark already
    /// says everything - no point captioning the normal cases.
    ///
    /// `notFound` deliberately has **no** message: an earlier version
    /// captioned it "move thrw to your Applications folder", which a real
    /// unsigned bundle proved wrong - `notFound` is simply what macOS
    /// reports before an app has ever registered, and `register()`
    /// succeeds from there (including from outside `/Applications`). That
    /// message would have alarmed every first-time user. A registration
    /// that genuinely fails throws, and the caller logs the real error
    /// rather than guessing at a cause here.
    public static func explanation(for state: LoginItemState) -> String? {
        switch state {
        case .enabled, .notRegistered, .notFound:
            return nil
        case .requiresApproval:
            return "Open at Login needs approval in System Settings \u{203A} General \u{203A} Login Items."
        }
    }
}

public enum LoginItemAction: Equatable, Sendable {
    case register
    case unregister
}
