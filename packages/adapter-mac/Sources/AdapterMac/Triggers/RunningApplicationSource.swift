import Foundation

/// As much as ``VoipTriggerMonitor`` needs to know about a running app -
/// its bundle identifier. Pure Swift mirror of the one
/// `NSRunningApplication` field that matters here, kept free of AppKit so
/// the monitor's own logic is unit-testable (see this file's kdoc and
/// ``NSWorkspaceRunningApplicationSource``'s for why the real source
/// isn't).
public struct RunningApplicationInfo: Equatable, Sendable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }
}

/// One app launching or terminating, as `NSWorkspace`'s own notifications
/// report them.
public enum RunningApplicationEvent: Equatable, Sendable {
    case launched(RunningApplicationInfo)
    case terminated(RunningApplicationInfo)
}

/// Thin seam over `NSWorkspace`'s running-application notifications that
/// ``VoipTriggerMonitor`` depends on - the "process watching" half of
/// architecture.md's "System components" line for Mac (the other half,
/// `AVAudioSession`, doesn't exist on macOS at all; see this package's
/// `docs/spec/architecture.md` correction and #127's handoff for why).
///
/// Modeled on `adapter-android`'s `NotificationSource`: real Bluetooth/
/// process-watching hardware and state isn't exercisable from a unit
/// test, so ``VoipTriggerMonitor``'s own tests fake this protocol
/// directly rather than driving real `NSWorkspace` notifications.
///
/// A single method rather than a snapshot-plus-stream pair: the "replay
/// already-running apps first" behavior
/// (`NotificationSource`'s own kdoc: "the getActiveNotifications() replay
/// a listener does on connect") is the real implementation's job
/// (`NSWorkspaceRunningApplicationSource`), not something every fake in
/// every test has to also reproduce.
public protocol RunningApplicationSource: Sendable {
    func events() -> AsyncStream<RunningApplicationEvent>
}
