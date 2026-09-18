import AdapterMac
import AppKit
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
    /// #144. A protocol rather than `SMAppServiceLoginItem` directly, so
    /// the decisions around it live in the testable ``LoginItem`` type.
    private let loginItem: LoginItemController = SMAppServiceLoginItem()
    private var openAtLoginItem: NSMenuItem?

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
        // #144. Checkable menu item rather than a settings window: this
        // is a single boolean on a menu-bar app, and it's where macOS
        // users already look for it. The provisioning window (#143) is
        // the right home for it once that lands; deliberately not a
        // second window here.
        let openAtLogin = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        openAtLogin.target = self
        menu.addItem(openAtLogin)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit thrw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Re-read the live state every time the menu opens, so a change
        // made in System Settings is reflected rather than a stale
        // remembered flag (#144 acceptance criterion 3).
        menu.delegate = self
        item.menu = menu

        openAtLoginItem = openAtLogin
        statusItem = item
        refreshOpenAtLoginItem()
    }

    /// Opt-in only (#144 acceptance criterion 5): registering a login
    /// item behind the user's back is the kind of thing that makes a
    /// utility feel hostile, so nothing here runs unless they click.
    @objc private func toggleOpenAtLogin() {
        let state = loginItem.currentState()
        do {
            switch LoginItem.action(for: state) {
            case .register: try loginItem.register()
            case .unregister: try loginItem.unregister()
            }
        } catch {
            Self.logger.error("Open at Login change failed: \(String(describing: error), privacy: .public)")
        }
        // Re-read rather than assuming the attempt worked - a failed
        // register must leave the checkmark showing reality.
        refreshOpenAtLoginItem()
    }

    private func refreshOpenAtLoginItem() {
        let state = loginItem.currentState()
        openAtLoginItem?.state = LoginItem.isOn(state) ? .on : .off
        // A state the user can't fix by clicking again (needs System
        // Settings, or the app isn't in a location macOS accepts) is
        // surfaced rather than silently leaving a toggle that won't move.
        openAtLoginItem?.toolTip = LoginItem.explanation(for: state)
        if let explanation = LoginItem.explanation(for: state) {
            Self.logger.info("Open at Login: \(explanation, privacy: .public)")
        }
    }

    /// Constructs and starts the real node, or logs why it didn't -
    /// never connects a half-configured node. No provisioning UI exists
    /// yet (#128's own acceptance criterion 4 excludes building one) -
    /// see ``AdapterProvisioning``'s own kdoc for the honest gap this
    /// leaves: today, nothing writes these `UserDefaults` keys.
    private func startNodeRuntimeIfProvisioned() async {
        guard let accountId = AdapterProvisioning.accountId() else {
            Self.logger.error("Not provisioned (no account id) - not starting a node")
            return
        }
        guard let headsetAddress = AdapterProvisioning.headsetAddress() else {
            Self.logger.error("Not provisioned (no headset address) - not starting a node")
            return
        }
        guard let headsetIdentifier = BluetoothDeviceIdentifier.identifier(forAddressString: headsetAddress) else {
            Self.logger.error("Configured headset address is not a valid Bluetooth address - not starting a node")
            return
        }

        do {
            let relayConfig = try RelayConfig.fromBuildConfig()
            let nodeId = DeviceIdentity.nodeId()
            let manifest = DeviceIdentity.manifest()

            let transport = try await MQTTNIOTransport.connect(config: relayConfig, clientId: nodeId)
            let bluetooth = BluetoothConnectionManager(gateway: IOBluetoothPeripheralGateway())
            let node = MacNode(
                accountId: accountId,
                nodeId: nodeId,
                headsetIdentifier: headsetIdentifier,
                transport: transport,
                bluetooth: bluetooth
            )

            let voipMonitor = VoipTriggerMonitor(source: NSWorkspaceRunningApplicationSource(), node: node)
            runtimeHandle = NodeRuntime(node: node, voipTriggerMonitor: voipMonitor).start(manifest: manifest)
        } catch {
            Self.logger.error("Failed to start node runtime: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Refreshes the Open at Login checkmark each time the menu is opened,
/// so a change the user made in System Settings shows up (#144).
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshOpenAtLoginItem()
    }
}
