import XCTest

@testable import AdapterMac

/// Mirrors `adapter-android`'s `ProvisioningInputTest.kt` case-for-case
/// where the rule is shared - the account-id rule in particular has to
/// stay byte-identical across platforms, since the same value addresses
/// the same MQTT topics from either one.
final class ProvisioningInputTests: XCTestCase {
    // MARK: account id

    func testAccountIdTrimsSurroundingWhitespaceRatherThanRejectingIt() {
        XCTAssertEqual(ProvisioningInput.accountId("  tom-personal \n"), .valid("tom-personal"))
    }

    func testABlankAccountIdIsRejectedAsBlankNotAsBadCharacters() {
        XCTAssertEqual(ProvisioningInput.accountId(""), .invalid(.accountIdBlank))
        XCTAssertEqual(ProvisioningInput.accountId("   "), .invalid(.accountIdBlank))
    }

    func testAccountIdAcceptsLettersDigitsDotUnderscoreAndHyphen() {
        XCTAssertEqual(ProvisioningInput.accountId("Tom.Personal_1-2"), .valid("Tom.Personal_1-2"))
    }

    /// The value is interpolated straight into every topic
    /// (`thrw/{account}/...`), so anything that would change the topic's
    /// shape or make it a wildcard subscription has to be rejected.
    func testAccountIdRejectsCharactersThatWouldBreakOrWidenAnMqttTopic() {
        for bad in ["tom/personal", "tom+personal", "tom#personal", "tom personal", "tom\u{00e9}"] {
            XCTAssertEqual(
                ProvisioningInput.accountId(bad),
                .invalid(.accountIdUnsupportedCharacters),
                "expected \(bad) to be rejected"
            )
        }
    }

    func testAccountIdIsCappedAtSixtyFourCharacters() {
        XCTAssertEqual(
            ProvisioningInput.accountId(String(repeating: "a", count: 64)),
            .valid(String(repeating: "a", count: 64))
        )
        XCTAssertEqual(
            ProvisioningInput.accountId(String(repeating: "a", count: 65)),
            .invalid(.accountIdUnsupportedCharacters)
        )
    }

    // MARK: headset address

    func testHeadsetAddressNormalizesToIOBluetoothsOwnDashSeparatedForm() {
        XCTAssertEqual(ProvisioningInput.headsetAddress("AA:BB:CC:DD:EE:FF"), .valid("aa-bb-cc-dd-ee-ff"))
        XCTAssertEqual(ProvisioningInput.headsetAddress("aa-bb-cc-dd-ee-ff"), .valid("aa-bb-cc-dd-ee-ff"))
        XCTAssertEqual(ProvisioningInput.headsetAddress("aabbccddeeff"), .valid("aa-bb-cc-dd-ee-ff"))
    }

    func testABlankHeadsetAddressIsRejectedAsBlank() {
        XCTAssertEqual(ProvisioningInput.headsetAddress("   "), .invalid(.headsetAddressBlank))
    }

    func testAMalformedHeadsetAddressIsRejected() {
        for bad in ["AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:FF:00", "ZZ:BB:CC:DD:EE:FF", "not-an-address"] {
            XCTAssertEqual(
                ProvisioningInput.headsetAddress(bad),
                .invalid(.headsetAddressMalformed),
                "expected \(bad) to be rejected"
            )
        }
    }

    /// The whole point of normalizing: whatever the user or picker hands
    /// over must round-trip into the `UUID` ``MacNode`` is constructed
    /// with, or the node silently fails to start later.
    func testANormalizedAddressResolvesToTheIdentifierMacNodeNeeds() throws {
        guard case .valid(let normalized) = ProvisioningInput.headsetAddress("AA:BB:CC:DD:EE:FF") else {
            return XCTFail("expected a valid address")
        }
        XCTAssertEqual(
            BluetoothDeviceIdentifier.identifier(forAddressString: normalized),
            BluetoothDeviceIdentifier.identifier(forAddressString: "AA:BB:CC:DD:EE:FF")
        )
    }
}
