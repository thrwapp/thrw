#if canImport(AppKit)

import AppKit
import Foundation

/// Real ``RunningApplicationSource``, backed by `NSWorkspace`'s
/// `didLaunchApplicationNotification`/`didTerminateApplicationNotification`.
///
/// Replays every already-running app with a bundle identifier as a
/// synthetic `.launched` event before yielding live notifications -
/// mirrors `NotificationListenerService`'s own `onListenerConnected`
/// replay on the Android side (same reasoning: a VoIP app already
/// running when this source starts observing must not be invisible to
/// ``VoipTriggerMonitor``).
///
/// `#if canImport(AppKit)`, matching `IOBluetoothPeripheralGateway`'s own
/// guard (#101): AppKit is Apple-only, so this file compiles nowhere
/// else. (An earlier version of this comment said the repo's agent
/// automation builds this on Linux - it does not; see `Package.swift`'s
/// `#if os(macOS)` comment.) Not exercised by this package's own tests either way - no
/// real `NSWorkspace` notifications in a unit test, same discipline
/// `IOBluetoothPeripheralGateway` and `MQTTNIOTransport` already follow;
/// only ``VoipTriggerMonitor``'s own logic is tested, against a fake.
public final class NSWorkspaceRunningApplicationSource: RunningApplicationSource {
    public init() {}

    public func events() -> AsyncStream<RunningApplicationEvent> {
        AsyncStream { continuation in
            let workspace = NSWorkspace.shared
            let center = workspace.notificationCenter

            for app in workspace.runningApplications {
                guard let bundleIdentifier = app.bundleIdentifier else { continue }
                continuation.yield(.launched(RunningApplicationInfo(bundleIdentifier: bundleIdentifier)))
            }

            let launchObserver = center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let bundleIdentifier = Self.bundleIdentifier(from: notification) else { return }
                continuation.yield(.launched(RunningApplicationInfo(bundleIdentifier: bundleIdentifier)))
            }

            let terminateObserver = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let bundleIdentifier = Self.bundleIdentifier(from: notification) else { return }
                continuation.yield(.terminated(RunningApplicationInfo(bundleIdentifier: bundleIdentifier)))
            }

            continuation.onTermination = { _ in
                center.removeObserver(launchObserver)
                center.removeObserver(terminateObserver)
            }
        }
    }

    private static func bundleIdentifier(from notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }
}

#endif
