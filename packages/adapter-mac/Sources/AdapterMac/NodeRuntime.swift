import Foundation

// `os` (and `os.Logger`) is an Apple-platform module that does not exist
// on Linux. Unlike AppKit, which is confined to the macOS-only
// AdapterMacApp target, this file is part of the AdapterMac *library*
// target, which does build on Linux - so the import has to be
// conditional and needs a real fallback, not an empty one. See
// Package.swift's `#if os(macOS)` comment for who actually builds this
// on Linux today (nothing in this repo does).
#if canImport(os)
import os
#endif

/// The composition root's testable half (#128's acceptance criterion 5,
/// mirroring `adapter-android`'s #96 acceptance criterion 4 - "a
/// testable factory function or dependency-injection seam"). Plain
/// Swift, no `AppKit`/`NSApplication` types - tested the same way
/// `MacNodeTests` already tests ``MacNode``: against fakes, with
/// `async`/`await`, no host app or run loop required.
///
/// The app's `AppDelegate` is the untestable half: it constructs the
/// *real* dependencies (``MacNode`` wired to ``MQTTNIOTransport``/
/// ``BluetoothConnectionManager``, a ``VoipTriggerMonitor`` wired to
/// ``NSWorkspaceRunningApplicationSource``) and hands them to this
/// class. This class knows nothing about where they came from - Swift
/// mirror of `adapter-android`'s `NodeRuntime.kt`.
///
/// Unlike Kotlin's `CoroutineScope.launch` (an already-existing
/// structured-concurrency scope every caller has), Swift has no
/// ambient equivalent - ``start(manifest:)`` creates its own unstructured
/// `Task`s directly and returns a ``NodeRuntimeHandle`` the caller uses
/// to cancel them together (the same role `AdapterForegroundService`'s
/// `job.cancel()` plays for the Kotlin `SupervisorJob`).
/// `@MainActor`-isolated rather than `Sendable`: ``VoipTriggerMonitor``
/// (#127) is a plain class with mutable state (`activeBundleIdentifiers`)
/// and is genuinely not `Sendable`, so a `Sendable` `NodeRuntime` holding
/// one is an error in the Swift 6 language mode. Main-actor isolation
/// protects that state instead - and is what this composition root wants
/// anyway, since ``IOBluetoothPeripheralGateway`` already requires the
/// main run loop (`docs/handoffs/101.md`). Not an AppKit dependency:
/// `@MainActor` is plain Swift concurrency, so this type still tests
/// without a host app (see `NodeRuntimeTests`).
@MainActor
public final class NodeRuntime {
    private let node: MacNode
    private let voipTriggerMonitor: VoipTriggerMonitor
    private let mediaTriggerMonitor: MediaTriggerMonitor
    private let heartbeatPublisher: HeartbeatPublisher
    private let registrationPublisher: RegistrationPublisher

    #if canImport(os)
    private static let logger = Logger(subsystem: "app.thrw.mac", category: "NodeRuntime")
    #endif

    /// `heartbeatPublisher` defaults to one beating `node` itself at the
    /// spec'd interval - callers only pass one explicitly to control
    /// timing in tests.
    public init(
        node: MacNode,
        voipTriggerMonitor: VoipTriggerMonitor,
        mediaTriggerMonitor: MediaTriggerMonitor,
        heartbeatPublisher: HeartbeatPublisher? = nil,
        registrationPublisher: RegistrationPublisher? = nil
    ) {
        self.node = node
        self.voipTriggerMonitor = voipTriggerMonitor
        self.mediaTriggerMonitor = mediaTriggerMonitor
        self.heartbeatPublisher = heartbeatPublisher ?? HeartbeatPublisher(sink: node)
        self.registrationPublisher = registrationPublisher ?? RegistrationPublisher()
    }

    /// Registers `manifest`, starts listening for relay commands, and
    /// starts the VoIP trigger monitor - each its own `Task`, so one
    /// throwing (or, for the monitor, its source stream simply
    /// completing) doesn't take the others down. Returns immediately;
    /// every launched task keeps running until cancelled via the
    /// returned handle.
    ///
    /// A task that throws is logged, not silently swallowed and not
    /// propagated - there's no Android-style OS-level service restart to
    /// fall back on here if an uncaught error were instead left to crash
    /// the whole process.
    @discardableResult
    public func start(manifest: NodeManifest) -> NodeRuntimeHandle {
        let registerTask = Task {
            await Self.logErrors(from: "register") { try await self.node.register(manifest: manifest) }
        }
        let commandsTask = Task {
            await Self.logErrors(from: "listenForCommands") { try await self.node.listenForCommands() }
        }
        let voipTask = Task {
            await Self.logErrors(from: "voipTriggerMonitor") { try await self.voipTriggerMonitor.run() }
        }
        // #142: without this the relay reaps this node ~90s after it
        // registers - and, since #130, publishes a RELEASE to it on the
        // way out, dropping the headset mid-call.
        //
        // Waits for `registerTask` first, rather than beating straight
        // away: the relay only subscribes to a node's heartbeat topic
        // when it sees that node's *registration*
        // (`relay-service.ts`'s `handleEvent` -> `trackHeartbeat`), so a
        // beat published before then lands on a topic nothing is
        // listening to. Registration also stamps the node's liveness on
        // the relay side, so there is no gap to cover by racing it.
        let mediaTask = Task {
            await Self.logErrors(from: "mediaTriggerMonitor") { try await self.mediaTriggerMonitor.run() }
        }
        let heartbeatTask = Task {
            _ = await registerTask.result
            await Self.logErrors(from: "heartbeatPublisher") { try await self.heartbeatPublisher.run() }
        }
        // #178: the relay holds its node list purely in memory and learns
        // of a node only from a registration, so a relay restart (or an
        // MQTT reconnect) leaves this node invisible until it registers
        // again. Re-sending periodically closes that; each send carries
        // the currently-active triggers, so it reconciles rather than
        // merely re-announcing.
        let reregisterTask = Task {
            _ = await registerTask.result
            await Self.logErrors(from: "registrationPublisher") {
                try await self.registrationPublisher.run {
                    try await self.node.register(manifest: manifest)
                }
            }
        }
        return NodeRuntimeHandle(
            tasks: [registerTask, commandsTask, voipTask, mediaTask, heartbeatTask, reregisterTask]
        )
    }

    private static func logErrors(from label: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch is CancellationError {
            // Expected on NodeRuntimeHandle.cancel() / app quit - not an error.
        } catch {
            logError("\(label) failed: \(String(describing: error))")
        }
    }

    /// `os.Logger` on Apple platforms (what `log stream`/Console.app
    /// pick up from the real menu-bar app), stderr on Linux, where that
    /// module doesn't exist. Not silently dropped on the non-Apple path:
    /// a swallowed error here would make a failing node look like an
    /// idle one.
    private static func logError(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("NodeRuntime: \(message)\n".utf8))
        #endif
    }
}

/// Cancellation handle for the tasks ``NodeRuntime/start(manifest:)``
/// launches - the composition root's equivalent of cancelling
/// `AdapterForegroundService`'s `SupervisorJob` on `onDestroy()`.
public struct NodeRuntimeHandle: Sendable {
    private let tasks: [Task<Void, Never>]

    init(tasks: [Task<Void, Never>]) {
        self.tasks = tasks
    }

    public func cancel() {
        for task in tasks { task.cancel() }
    }
}
