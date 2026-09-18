import Foundation

/// Whether this Mac is configured well enough to run a node, and if not,
/// why. #143's acceptance criterion 5 asks the window to show honest
/// status rather than leaving "I pressed save and nothing happened" as
/// the experience; this is the part of that decision that can be unit
/// tested, separate from any UI.
public enum ProvisioningState: Equatable, Sendable {
    case notProvisioned(missing: Missing)
    case provisioned(accountId: String, headsetIdentifier: UUID)

    public enum Missing: Equatable, Sendable {
        case accountId
        case headsetAddress
        /// Both values are present, but the stored address no longer
        /// parses - e.g. it was written by an older build, or edited by
        /// hand via `defaults write`. Distinct from "not set yet",
        /// because the user needs telling that something is *wrong*
        /// rather than merely absent.
        case headsetAddressUnusable(String)
    }
}

/// Reads persisted provisioning and decides whether a node can start.
///
/// The same decision `AppDelegate.startNodeRuntimeIfProvisioned` made
/// inline before #143, lifted out so it's testable and so the window and
/// the launch path can't disagree about what "provisioned" means.
public enum ProvisioningStatus {
    public static func current(defaults: UserDefaults = .standard) -> ProvisioningState {
        guard let accountId = AdapterProvisioning.accountId(defaults: defaults),
              !accountId.isEmpty
        else {
            return .notProvisioned(missing: .accountId)
        }
        guard let headsetAddress = AdapterProvisioning.headsetAddress(defaults: defaults),
              !headsetAddress.isEmpty
        else {
            return .notProvisioned(missing: .headsetAddress)
        }
        guard let identifier = BluetoothDeviceIdentifier.identifier(forAddressString: headsetAddress) else {
            return .notProvisioned(missing: .headsetAddressUnusable(headsetAddress))
        }
        return .provisioned(accountId: accountId, headsetIdentifier: identifier)
    }
}
