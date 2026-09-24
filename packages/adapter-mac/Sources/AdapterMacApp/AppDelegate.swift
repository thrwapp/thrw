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

    /// Held so its title can be flipped between claim, release and - as
    /// of #234 - a disabled readout when the hold is not the user's
    /// doing.
    private var claimItem: NSMenuItem?

    /// #265. Hidden unless this Mac is currently muted for a handover.
    private var unmuteItem: NSMenuItem?

    /// #234. The last derived claim action, kept because
    /// `validateMenuItem` is asked about enablement separately from
    /// `refreshClaimItem` setting the title, and the two must agree.
    private var currentClaimAction = ClaimAction(title: claimTitle, isEnabled: true)

    /// #265. Held so the menu can ask whether it is suppressing, and
    /// un-mute on request. Nil until a node runtime starts.
    private var audioGate: MutingHandoverAudioGate?

    /// #213. Disabled - it is a readout, not a control.
    private var statusMenuItem: NSMenuItem?

    /// The running node, kept so the status line can ask it. Nil until
    /// one starts.
    private var node: MacNode?

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

        // #213. First, because when something is wrong this is the
        // question you actually have: is it even working? Disabled
        // because it is a readout. Refreshed in `menuWillOpen` rather
        // than on a timer - nobody reads a closed menu, and polling would
        // cost battery to keep a string nobody is looking at current.
        let status = NSMenuItem(title: NodeStatus.disconnected.displayText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        statusMenuItem = status

        // #212. First item, because it is the thing you reach for when
        // the automation has just got it wrong - ADR 0010's "direct user
        // action always wins", made reachable.
        let claim = NSMenuItem(title: Self.claimTitle, action: #selector(toggleManualClaim), keyEquivalent: "k")
        claim.target = self
        menu.addItem(claim)
        claimItem = claim

        // #265. Hidden unless this Mac is actually muted for a handover.
        //
        // macOS suppresses handover audio by muting rather than pausing
        // (ADR 0022's amendment; #267 switches it once #132 lands), and
        // a mute is invisible: after a release this Mac stays silenced
        // until it is claimed again, with nothing on screen connecting
        // the silence to a headset switcher. This item is that
        // connection, and the way out of it.
        let unmute = NSMenuItem(title: Self.unmuteTitle, action: #selector(unmuteAfterHandover), keyEquivalent: "")
        unmute.target = self
        unmute.isHidden = true
        menu.addItem(unmute)
        menu.addItem(.separator())
        unmuteItem = unmute

        let setUpItem = NSMenuItem(title: "Set Up\u{2026}", action: #selector(openProvisioning), keyEquivalent: ",")
        setUpItem.target = self
        menu.addItem(setUpItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit thrw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu

        statusItem = item
    }

    /// Opens (or re-focuses) the provisioning window - #143. An
    /// `LSUIElement` app has no Dock icon and isn't normally activated,
    /// so this has to activate explicitly or the window opens behind
    /// whatever the user was doing.
    private static let claimTitle = "Claim Headset"
    private static let unmuteTitle = "Muted for Handover \u{2014} Unmute"

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

    private func refreshStatusItem() {
        // No node yet means nothing has connected, which is precisely
        // what "disconnected" says - true rather than a placeholder.
        statusMenuItem?.title = (node?.status() ?? .disconnected).displayText
    }

    /// #234. Derived from the relay's holder and this node's own
    /// triggers, not from ``ManualClaim/isHeld()`` alone - see
    /// ``claimAction(holdsClaim:manualClaimHeld:because:)`` for the rule
    /// and for the bug it replaces.
    private func refreshClaimItem() {
        currentClaimAction = claimAction(
            holdsClaim: node?.holdsClaim(),
            manualClaimHeld: manualClaim?.isHeld() ?? false,
            because: node?.mostRecentTrigger()
        )
        claimItem?.title = currentClaimAction.title
    }

    /// #265. Asynchronous because ``HandoverAudioGate/isSuppressing()``
    /// is - the gate is an actor. That is one actor hop, not I/O, so the
    /// item settles faster than the menu draws; and an `NSMenuItem`
    /// updated while its menu is open takes effect immediately, so there
    /// is no need to block the open on it.
    private func refreshUnmuteItem() {
        guard let unmuteItem else { return }
        guard let audioGate else {
            unmuteItem.isHidden = true
            return
        }
        Task { @MainActor in
            unmuteItem.isHidden = await !audioGate.isSuppressing()
        }
    }

    /// #265 acceptance criterion 2: restores the volume **and** clears
    /// the stored record.
    ///
    /// Both halves matter. ``MutingHandoverAudioGate/restore()`` does
    /// exactly that, which is why this calls it rather than setting a
    /// volume directly: leaving the record behind would let the next
    /// claim's restore overwrite whatever the user chose afterwards.
    @objc private func unmuteAfterHandover() {
        guard let audioGate else { return }
        Task { @MainActor in
            await audioGate.restore()
            self.refreshUnmuteItem()
        }
    }

    /// Disabled until a node is running: without one there is nothing to
    /// claim through, and an item that silently does nothing is worse
    /// than one that is visibly unavailable.
    ///
    /// #234 adds the second condition. A node holding the headset
    /// because of `media`, `voip` or `call` shows a greyed-out readout
    /// naming the reason: a node can only end its *own* triggers, so
    /// there is genuinely no action to offer, and the same argument
    /// against a control that silently does nothing applies.
    ///
    /// Enablement lives here rather than on `isEnabled` because the menu
    /// auto-enables its items, which overrides anything set directly.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === claimItem { return manualClaim != nil && currentClaimAction.isEnabled }
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
            // #191: the route observer needs the headset's Bluetooth
            // address, not the UUID the rest of the node uses - CoreAudio
            // spells a Bluetooth device's UID with its MAC. Read from
            // provisioning rather than derived from the UUID, because
            // that mapping is one-way.
            let routeObserver = AdapterProvisioning.headsetAddress().map(CoreAudioRouteObserver.init)
            if routeObserver == nil {
                Self.logger.error("No headset address for the route observer - route reconciliation is off (#191)")
            }
            // #225: the same observation, handed to the connection
            // manager as well, so a claim is not skipped on a cached
            // `.connected` that multipoint has already invalidated (ADR
            // 0018 decision 3). Built here rather than inside the
            // manager because this is the only place that knows both
            // halves - the headset's UUID and its Bluetooth address.
            let routeSource = routeObserver.map {
                HeadsetAudioRouteSource(headsetIdentifier: headsetIdentifier, observer: $0)
            }
            let bluetooth = BluetoothConnectionManager(
                gateway: IOBluetoothPeripheralGateway(),
                routeSource: routeSource
            )
            // ADR 0022 / #254: silences this Mac across the ~2.7s of a
            // handover where neither device holds the headset, so audio
            // does not fall back to the built-in speakers.
            //
            // `UserDefaults`-backed rather than in-memory, and for a
            // sharper reason than the sequence store below: the record
            // is what the pre-mute volume gets restored *from*. Losing
            // it with the process would leave the user muted with
            // nothing on screen explaining why, which is why ADR 0022's
            // amendment makes durability a requirement of choosing to
            // mute at all.
            let audioGate = MutingHandoverAudioGate(
                volume: CoreAudioSystemOutputVolume(),
                store: UserDefaultsMutedVolumeStore()
            )
            // #265: the menu asks this one whether it is suppressing, and
            // offers the way out.
            self.audioGate = audioGate
            // The other half of that requirement: a crash inside a
            // handover window self-heals on this launch rather than
            // persisting.
            //
            // Unstructured, so it is *not* ordered against the runtime
            // starting below - a command could beat it. That is safe
            // because the gate is an actor, so this and `silence()`
            // cannot interleave, and both orderings end correctly:
            // recovery-first restores and clears, leaving the claim to
            // record afresh; claim-first finds the record already held,
            // leaves it alone, and its own restore consumes it - after
            // which recovery finds nothing to do.
            Task { await audioGate.restoreAfterPreviousRun() }
            let node = MacNode(
                accountId: accountId,
                nodeId: nodeId,
                headsetIdentifier: headsetIdentifier,
                transport: transport,
                bluetooth: bluetooth,
                routeObserver: routeObserver,
                // #210: the persisted high-water mark. In-memory is
                // MacNode's default and is not enough here - the app is
                // relaunched at every login (#144's login item), and a
                // mark that died with the process would let the
                // broker's QoS 1 redelivery re-run a command already
                // acted on.
                sequenceGate: CommandSequenceGate(store: UserDefaultsSequenceStore()),
                audioGate: audioGate
            )
            self.node = node
            manualClaim = ManualClaim(node: node)
            refreshClaimItem()
            refreshStatusItem()

            // #247: the microphone is the second signal. A known VoIP app
            // merely being *open* is not a call, and because `voip`
            // outranks `media`, leaving Slack or WhatsApp running used to
            // pin the headset to this Mac indefinitely - no amount of
            // deliberate playback elsewhere could win it back.
            let voipMonitor = VoipTriggerMonitor(
                source: NSWorkspaceRunningApplicationSource(),
                node: node,
                microphone: CoreAudioMicrophoneActivitySource()
            )
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

extension AppDelegate: NSMenuDelegate {
    /// #213. Refreshed only when the menu opens: the status is read at a
    /// glance, and recomputing it on a timer would burn battery keeping a
    /// string current that nobody is looking at.
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusItem()
        refreshClaimItem()
        refreshUnmuteItem()
    }
}
