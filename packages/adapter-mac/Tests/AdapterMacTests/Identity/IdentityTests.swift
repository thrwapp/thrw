import XCTest

@testable import AdapterMac

/// Tests ``DeviceIdentity`` and ``AdapterProvisioning`` against a
/// throwaway `UserDefaults` suite rather than `.standard`, so these
/// never read or write the real user's defaults - the macOS equivalent
/// of `adapter-android`'s `AdapterProvisioningTest` faking the
/// `SharedPreferences` interface.
final class IdentityTests: XCTestCase {
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

    func testNodeIdIsGeneratedOnceAndThenStableAcrossCalls() {
        let first = DeviceIdentity.nodeId(defaults: defaults)
        let second = DeviceIdentity.nodeId(defaults: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first), "expected a UUID string, got \(first)")
    }

    func testNodeIdIsPersistedSoAFreshReadOfTheSameSuiteSeesIt() {
        let generated = DeviceIdentity.nodeId(defaults: defaults)

        let reopened = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(DeviceIdentity.nodeId(defaults: reopened), generated)
    }

    func testManifestReportsMacAndOnlyTheEventKindsThisAdapterCanActuallyDetect() {
        let manifest = DeviceIdentity.manifest(defaults: defaults)

        XCTAssertEqual(manifest.platform, .mac)
        XCTAssertEqual(manifest.nodeId, DeviceIdentity.nodeId(defaults: defaults))
        XCTAssertEqual(manifest.adapterVersion, DeviceIdentity.adapterVersion)
        // `.voip` (#127) and `.media` (#166). Not `.call`: macOS has no
        // call-detection API at all (#127) - see DeviceIdentity.manifest's
        // own kdoc. Not `.manual_claim`: nothing emits it, there's no UI.
        XCTAssertEqual(manifest.supportedEventKinds, [.voip, .media])
        XCTAssertFalse(manifest.displayName.isEmpty)
    }

    func testProvisioningReportsNilUntilSetThenRoundTripsBothValues() {
        XCTAssertNil(AdapterProvisioning.accountId(defaults: defaults))
        XCTAssertNil(AdapterProvisioning.headsetAddress(defaults: defaults))

        AdapterProvisioning.setAccountId("tom-personal", defaults: defaults)
        AdapterProvisioning.setHeadsetAddress("AA:BB:CC:DD:EE:FF", defaults: defaults)

        XCTAssertEqual(AdapterProvisioning.accountId(defaults: defaults), "tom-personal")
        XCTAssertEqual(AdapterProvisioning.headsetAddress(defaults: defaults), "AA:BB:CC:DD:EE:FF")
    }

    /// The composition root converts the stored address string into the
    /// `UUID` ``MacNode`` needs - see ``AdapterProvisioning``'s kdoc for
    /// why the raw string is what's persisted.
    func testAStoredHeadsetAddressConvertsToTheIdentifierMacNodeExpects() throws {
        AdapterProvisioning.setHeadsetAddress("AA:BB:CC:DD:EE:FF", defaults: defaults)

        let stored = try XCTUnwrap(AdapterProvisioning.headsetAddress(defaults: defaults))
        let identifier = BluetoothDeviceIdentifier.identifier(forAddressString: stored)

        XCTAssertEqual(identifier, BluetoothDeviceIdentifier.identifier(forAddressString: "AA:BB:CC:DD:EE:FF"))
    }
}
