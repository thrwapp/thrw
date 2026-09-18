import AdapterMac
import SwiftUI

/// Drives ``ProvisioningView``. Holds only what the window needs to
/// render; every rule it applies lives in `AdapterMac`'s unit-tested
/// plain-Swift types rather than here.
@MainActor
final class ProvisioningViewModel: ObservableObject {
    @Published var accountId: String = ""
    @Published var selectedHeadsetAddress: String?
    @Published var headsetsState: PairedHeadsetsState = .noDevicesPaired
    @Published var accountIdError: String?
    @Published var headsetError: String?
    @Published private(set) var statusText: String = ""
    @Published private(set) var isRunning: Bool = false
    /// #144. Reflects the *system's* current answer, re-read on every
    /// appearance and after every change - never a remembered flag, since
    /// the user can revoke a login item in System Settings without
    /// telling the app.
    @Published private(set) var opensAtLogin: Bool = false
    @Published private(set) var loginItemNote: String?

    private let deviceSource: PairedDeviceSource
    private let loginItem: LoginItemController
    private let defaults: UserDefaults
    /// Called after a successful save, so the app can (re)start the node
    /// without an app relaunch - #143 acceptance criterion 4.
    private let onProvisioned: () async -> Void

    init(
        deviceSource: PairedDeviceSource,
        loginItem: LoginItemController,
        defaults: UserDefaults = .standard,
        onProvisioned: @escaping () async -> Void
    ) {
        self.deviceSource = deviceSource
        self.loginItem = loginItem
        self.defaults = defaults
        self.onProvisioned = onProvisioned

        accountId = AdapterProvisioning.accountId(defaults: defaults) ?? ""
        selectedHeadsetAddress = AdapterProvisioning.headsetAddress(defaults: defaults)
        refreshStatus()
    }

    var statusColor: Color {
        isRunning ? .green : .secondary
    }

    func reloadDevices() {
        headsetsState = PairedHeadsets.state(pairedDevices: deviceSource.pairedDevices())
        refreshLoginItem()
    }

    /// Opt-in only (#144 acceptance criterion 5): nothing registers
    /// unless the user flips this.
    func toggleOpenAtLogin() {
        do {
            switch LoginItem.action(for: loginItem.currentState()) {
            case .register: try loginItem.register()
            case .unregister: try loginItem.unregister()
            }
        } catch {
            loginItemNote = "Couldn't change Open at Login."
        }
        // Re-read rather than assuming the attempt worked, so a failed
        // register leaves the toggle showing reality.
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        let state = loginItem.currentState()
        opensAtLogin = LoginItem.isOn(state)
        loginItemNote = LoginItem.explanation(for: state)
    }

    /// Validates both fields, persists them only if *both* are good, then
    /// asks the app to start the node.
    ///
    /// All-or-nothing on purpose: `AdapterProvisioning`'s two setters are
    /// separate writes, and persisting a valid account id alongside a
    /// rejected headset would leave the app in a half-configured state
    /// that reads as "provisioned enough to try" on the next launch.
    func save() {
        accountIdError = nil
        headsetError = nil

        let accountResult = ProvisioningInput.accountId(accountId)
        let addressResult = ProvisioningInput.headsetAddress(selectedHeadsetAddress ?? "")

        var validAccount: String?
        var validAddress: String?

        switch accountResult {
        case .valid(let value): validAccount = value
        case .invalid(let error): accountIdError = Self.message(for: error)
        }
        switch addressResult {
        case .valid(let value): validAddress = value
        case .invalid(let error): headsetError = Self.message(for: error)
        }

        guard let validAccount, let validAddress else {
            refreshStatus()
            return
        }

        AdapterProvisioning.setAccountId(validAccount, defaults: defaults)
        AdapterProvisioning.setHeadsetAddress(validAddress, defaults: defaults)
        // Show the normalized values, so the user sees exactly what was
        // stored rather than what they typed.
        accountId = validAccount
        selectedHeadsetAddress = validAddress

        refreshStatus()
        Task {
            await onProvisioned()
            isRunning = true
            refreshStatus()
        }
    }

    /// Lets the app tell the window the node stopped (e.g. a failed
    /// connect), so the indicator doesn't claim it's running.
    func nodeStopped() {
        isRunning = false
        refreshStatus()
    }

    private func refreshStatus() {
        switch ProvisioningStatus.current(defaults: defaults) {
        case .notProvisioned(.accountId):
            statusText = "Not set up \u{2014} enter an account ID."
        case .notProvisioned(.headsetAddress):
            statusText = "Not set up \u{2014} choose a headset."
        case .notProvisioned(.headsetAddressUnusable(let stored)):
            statusText = "Saved headset address isn't usable (\(stored)) \u{2014} choose one again."
        case .provisioned:
            statusText = isRunning ? "Connected to the relay." : "Set up. Save to connect."
        }
    }

    private static func message(for error: ProvisioningInput.FieldError) -> String {
        switch error {
        case .accountIdBlank:
            return "Enter an account ID."
        case .accountIdUnsupportedCharacters:
            return "Use only letters, digits, dot, underscore or hyphen (max 64)."
        case .headsetAddressBlank:
            return "Choose a headset."
        case .headsetAddressMalformed:
            return "That headset address isn't valid."
        }
    }
}
