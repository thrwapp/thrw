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

    private let deviceSource: PairedDeviceSource
    private let defaults: UserDefaults
    /// Called after a successful save, so the app can (re)start the node
    /// without an app relaunch - #143 acceptance criterion 4.
    private let onProvisioned: () async -> Void

    init(
        deviceSource: PairedDeviceSource,
        defaults: UserDefaults = .standard,
        onProvisioned: @escaping () async -> Void
    ) {
        self.deviceSource = deviceSource
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
