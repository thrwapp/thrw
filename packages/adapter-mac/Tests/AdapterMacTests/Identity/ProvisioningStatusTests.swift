import XCTest

@testable import AdapterMac

/// Against a throwaway `UserDefaults` suite, never `.standard` - the same
/// discipline `IdentityTests` uses, so these never touch the real user's
/// provisioning.
final class ProvisioningStatusTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "app.thrw.mac.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAFreshMachineIsMissingItsAccountId() {
        XCTAssertEqual(ProvisioningStatus.current(defaults: defaults), .notProvisioned(missing: .accountId))
    }

    func testAnAccountIdAloneIsStillMissingTheHeadset() {
        AdapterProvisioning.setAccountId("tom-personal", defaults: defaults)

        XCTAssertEqual(ProvisioningStatus.current(defaults: defaults), .notProvisioned(missing: .headsetAddress))
    }

    func testBothValuesPresentResolvesToProvisionedWithTheIdentifierMacNodeNeeds() {
        AdapterProvisioning.setAccountId("tom-personal", defaults: defaults)
        AdapterProvisioning.setHeadsetAddress("aa-bb-cc-dd-ee-ff", defaults: defaults)

        XCTAssertEqual(
            ProvisioningStatus.current(defaults: defaults),
            .provisioned(
                accountId: "tom-personal",
                headsetIdentifier: BluetoothDeviceIdentifier.identifier(forAddressString: "aa-bb-cc-dd-ee-ff")!
            )
        )
    }

    /// A stored address that no longer parses (older build, or a hand-
    /// edited `defaults write`) is *wrong*, not merely absent - the user
    /// needs telling the difference, so it gets its own case rather than
    /// collapsing into `.headsetAddress`.
    func testAnUnparseableStoredAddressIsReportedAsUnusableNotAsMissing() {
        AdapterProvisioning.setAccountId("tom-personal", defaults: defaults)
        AdapterProvisioning.setHeadsetAddress("not-an-address", defaults: defaults)

        XCTAssertEqual(
            ProvisioningStatus.current(defaults: defaults),
            .notProvisioned(missing: .headsetAddressUnusable("not-an-address"))
        )
    }

    func testAnEmptyStoredValueCountsAsMissingRatherThanProvisioned() {
        AdapterProvisioning.setAccountId("", defaults: defaults)

        XCTAssertEqual(ProvisioningStatus.current(defaults: defaults), .notProvisioned(missing: .accountId))
    }

    /// End-to-end through the layer the window actually uses: validated
    /// input, persisted, then read back as provisioned.
    func testValidatedInputPersistsAndThenReadsBackAsProvisioned() throws {
        guard case .valid(let account) = ProvisioningInput.accountId("  tom-personal  "),
              case .valid(let address) = ProvisioningInput.headsetAddress("AA:BB:CC:DD:EE:FF")
        else {
            return XCTFail("expected both fields to validate")
        }

        AdapterProvisioning.setAccountId(account, defaults: defaults)
        AdapterProvisioning.setHeadsetAddress(address, defaults: defaults)

        guard case .provisioned(let storedAccount, _) = ProvisioningStatus.current(defaults: defaults) else {
            return XCTFail("expected provisioned")
        }
        XCTAssertEqual(storedAccount, "tom-personal")
    }
}
