import AdapterMac
import AppKit
import SwiftUI
import os

/// The composition root's untestable half (#128) - a menu-bar
/// `NSApplication` per ADR 0004 ("a menu bar icon, a keyboard shortcut,
/// and a background process"; no Electron/Tauri). Constructs the real
/// ``MacNode`` wired to ``MQTTNIOTransport``/``BluetoothConnectionManager``,
/// and a real ``VoipTriggerMonitor`` wired to
/// ``NSWorkspaceRunningApplicationSource``, then hands both to
/// ``NodeRuntime`` (the testable half - see its own kdoc for the split,
/// mirroring `adapter-android`'s `AdapterForegroundService`/`NodeRuntime`
/// split).
///
/// `@MainActor` (not just AppKit's own implicit isolation) because
/// ``IOBluetoothPeripheralGateway`` requires the host process's main run
/// loop to be running on the thread that opened the Bluetooth connection
/// (`docs/handoffs/101.md`) - a plain `NSApplication.run()` on the main
/// thread satisfies that, and this class's own async work stays on that
/// same actor by construction (a `Task` created from `@MainActor` code
/// inherits that isolation).
///
/// Does not implement the connection state machine (idle/pre-claim/
/// claim/active) - frozen contract per ADR 0010/0011/0013, out of scope
/// here, same as ``MacNode`` itself.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "app.thrw.mac", category: "AppDelegate")

    private var statusItem: NSStatusItem?
    private var runtimeHandle: NodeRuntimeHandle?
    /// Held so a restart can close the old connection before opening a
    /// new one - otherwise re-saving provisioning leaks an MQTT client
    /// per save, each still subscribed to the old node's commands topic.
    private var transport: MQTTNIOTransport?
    private var provisioningWindow: NSWindow?
    private var provisioningModel: ProvisioningViewModel?
    /// Guards against two overlapping starts (double-click Save, or Save
    /// racing the launch-time start) producing two live nodes.
    private var isStarting = false
    /// #144. A protocol rather than `SMAppServiceLoginItem` directly, so
    /// the decisions around it live in the testable ``LoginItem`` type.
    /// Handed to the provisioning window, which owns the toggle: #143
    /// landed first, and #144's own criterion 2 says the toggle belongs
    /// in that window once it exists rather than in a second surface.
    private let loginItem: LoginItemController = SMAppServiceLoginItem()

    /// #212. Non-nil only while a node runtime is running - the menu item
    /// is disabled otherwise, because there is nothing to claim through.
    private var manualClaim: ManualClaim?

    /// Held so its title can be flipped between claim and release.
    private var claimItem: NSMenuItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        Task { await startNodeRuntimeIfProvisioned() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeHandle?.cancel()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "thrw")

        let menu = NSMenu()

        // #212. First item, because it is the thing you reach for when
        // the automation has just got it wrong - ADR 0010's "direct user
        // action always wins", made reachable.
        let claim = NSMenuItem(title: Self.claimTitle, action: #selector(toggleManualClaim), keyEquivalent: "k")
        claim.target = self
        menu.addItem(claim)
        menu.addItem(.separator())
        claimItem = claim

        let setUpItem = NSMenuItem(title: "Set Up\u{2026}", action: #selector(openProvisioning), keyEquivalent: ",")
        setUpItem.target = self
        menu.addItem(setUpItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit thrw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    /// Opens (or re-focuses) the provisioning window - #143. An
    /// `LSUIElement` app has no Dock icon and isn't normally activated,
    /// so this has to activate explicitly or the window opens behind
    /// whatever the user was doing.
    private static let claimTitle = "Claim Headset"
    private static let releaseTitle = "Release Headset"

    /// #212. The publish is awaited before the title changes, so the menu
    /// never claims a state the relay was not actually told about - a
    /// failed claim leaves the item as it was, and the next tap retries.
    @objc private func toggleManualClaim() {
        guard let manualClaim else { return }
        Task { @MainActor in
            do {
                _ = try await manualClaim.toggle()
            } catch {
                // Logged rather than swallowed: the title stays as it was,
                // so the menu keeps telling the truth and the next tap
                // retries.
                Self.logger.error("Manual claim failed: \(error.localizedDescription, privacy: .public)")
            }
            self.refreshClaimItem()
        }
    }

    private func refreshClaimItem() {
        claimItem?.title = (manualClaim?.isHeld() ?? false) ? Self.releaseTitle : Self.claimTitle
    }

    /// Disabled until a node is running: without one there is nothing to
    /// claim through, and an item that silently does nothing is worse
    /// than one that is visibly unavailable.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === claimItem { return manualClaim != nil }
        return true
    }

    @objc private func openProvisioning() {
        if let provisioningWindow {
            NSApp.activate(ignoringOtherApps: true)
            provisioningWindow.makeKeyAndOrderFront(nil)
            provisioningModel?.reloadDevices()
            return
        }

        let model = ProvisioningViewModel(
            deviceSource: IOBluetoothPairedDeviceSource(),
            loginItem: loginItem,
            onProvisioned: { [weak self] in await self?.restartNodeRuntime() }
        )
        provisioningModel = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "thrw"
        window.contentView = NSHostingView(rootView: ProvisioningView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        provisioningWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Tears the current node down and starts a fresh one from whatever
    /// provisioning is now stored (#143 acceptance criterion 4). Cancels
    /// the old tasks *and* closes the old transport before reconnecting -
    /// leaving the old MQTT client open would keep a second subscriber on
    /// the previous node's commands topic.
    private func restartNodeRuntime() async {
        runtimeHandle?.cancel()
        runtimeHandle = nil
        if let transport {
            self.transport = nil
            try? await transport.close()
        }
        await startNodeRuntimeIfProvisioned()
    }

    /// Constructs and starts the real node, or logs why it didn't -
    /// never connects a half-configured node.
    ///
    /// The provisioned/not decision comes from ``ProvisioningStatus``
    /// (#143) rather than being re-derived here, so this path and the
    /// provisioning window can't disagree about what "provisioned" means.
    /// Since #143 this is re-callable: saving in the window restarts the
    /// node without an app relaunch.
    private func startNodeRuntimeIfProvisioned() async {
        guard !isStarting else {
            Self.logger.error("A node start is already in flight - ignoring this one")
            return
        }
        isStarting = true
        defer { isStarting = false }

        let accountId: String
        let headsetIdentifier: UUID
        switch ProvisioningStatus.current() {
        case .notProvisioned(.accountId):
            Self.logger.error("Not provisioned (no account id) - not starting a node")
            provisioningModel?.nodeStopped()
            return
        case .notProvisioned(.headsetAddress):
            Self.logger.error("Not provisioned (no headset address) - not starting a node")
            provisioningModel?.nodeStopped()
            return
        case .notProvisioned(.headsetAddressUnusable(let stored)):
            Self.logger.error("Stored headset address is unusable (\(stored, privacy: .public)) - not starting a node")
            provisioningModel?.nodeStopped()
            return
        case .provisioned(let account, let identifier):
            accountId = account
            headsetIdentifier = identifier
        }

        do {
            let relayConfig = try RelayConfig.fromBuildConfig()
            let nodeId = DeviceIdentity.nodeId()
            let manifest = DeviceIdentity.manifest()

            // #147: nil when unset, which connects anonymously - correct
            // for a local broker, rejected by the deployed relay.
            let credentials = RelayCredentials.fromBuildConfig()
            if credentials == nil {
                Self.logger.error("No relay credential configured - see config/adapter.properties (#147)")
            }
            let transport = try await MQTTNIOTransport.connect(
                config: relayConfig,
                clientId: nodeId,
                credentials: credentials
            )
            self.transport = transport
            let bluetooth = BluetoothConnectionManager(gateway: IOBluetoothPeripheralGateway())
            // #191: the route observer needs the headset's Bluetooth
            // address, not the UUID the rest of the node uses - CoreAudio
            // spells a Bluetooth device's UID with its MAC. Read from
            // provisioning rather than derived from the UUID, because
            // that mapping is one-way.
            let routeObserver = AdapterProvisioning.headsetAddress().map(CoreAudioRouteObserver.init)
            if routeObserver == nil {
                Self.logger.error("No headset address for the route observer - route reconciliation is off (#191)")
            }
            let node = MacNode(
                accountId: accountId,
                nodeId: nodeId,
                headsetIdentifier: headsetIdentifier,
                transport: transport,
                bluetooth: bluetooth,
                routeObserver: routeObserver
            )
            manualClaim = ManualClaim(node: node)
            refreshClaimItem()

            let voipMonitor = VoipTriggerMonitor(source: NSWorkspaceRunningApplicationSource(), node: node)
            // #166: media (rule 4), via public CoreAudio.
            let mediaMonitor = MediaTriggerMonitor(source: CoreAudioPlaybackSource(), node: node)
            runtimeHandle = NodeRuntime(node: node, voipTriggerMonitor: voipMonitor, mediaTriggerMonitor: mediaMonitor)
                .start(manifest: manifest)
            Self.logger.info("Node runtime started for account \(accountId, privacy: .public)")
        } catch {
            Self.logger.error("Failed to start node runtime: \(String(describing: error), privacy: .public)")
            transport = nil
            provisioningModel?.nodeStopped()
        }
    }
}
