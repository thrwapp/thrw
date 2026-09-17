import XCTest

@testable import AdapterMac

/// The address ⇄ identifier mapping is the one part of the
/// `IOBluetooth`-backed gateway that is pure logic, so it's the one part
/// that can be tested without Bluetooth hardware (which no CI runner
/// has). `IOBluetoothPeripheralGateway` itself stays untested here — see
/// `docs/handoffs/101.md`.
final class BluetoothDeviceIdentifierTests: XCTestCase {
    func testIdentifierCarriesTheAddressInItsLastField() {
        let identifier = BluetoothDeviceIdentifier.identifier(forAddressString: "00-11-22-33-44-55")

        XCTAssertEqual(identifier?.uuidString.lowercased(), "74687277-6274-8000-8000-001122334455")
    }

    func testIdentifierRoundTripsBackToAnIOBluetoothFormattedAddress() {
        let identifier = BluetoothDeviceIdentifier.identifier(forAddressString: "a0-b1-c2-d3-e4-f5")

        let addressString = identifier.flatMap(BluetoothDeviceIdentifier.addressString(for:))
        XCTAssertEqual(addressString, "a0-b1-c2-d3-e4-f5")
    }

    func testAllSeparatorStylesAndCasesProduceTheSameIdentifier() {
        let dashed = BluetoothDeviceIdentifier.identifier(forAddressString: "A0-B1-C2-D3-E4-F5")
        let colons = BluetoothDeviceIdentifier.identifier(forAddressString: "a0:b1:c2:d3:e4:f5")
        let bare = BluetoothDeviceIdentifier.identifier(forAddressString: "a0b1c2d3e4f5")
        let spaced = BluetoothDeviceIdentifier.identifier(forAddressString: "a0 b1 c2 d3 e4 f5")

        XCTAssertNotNil(dashed)
        XCTAssertEqual(dashed, colons)
        XCTAssertEqual(dashed, bare)
        XCTAssertEqual(dashed, spaced)
    }

    func testDifferentAddressesProduceDifferentIdentifiers() {
        let first = BluetoothDeviceIdentifier.identifier(forAddressString: "00-11-22-33-44-55")
        let second = BluetoothDeviceIdentifier.identifier(forAddressString: "00-11-22-33-44-56")

        XCTAssertNotEqual(first, second)
    }

    func testMalformedAddressesHaveNoIdentifier() {
        XCTAssertNil(BluetoothDeviceIdentifier.identifier(forAddressString: ""))
        XCTAssertNil(BluetoothDeviceIdentifier.identifier(forAddressString: "00-11-22-33-44"))
        XCTAssertNil(BluetoothDeviceIdentifier.identifier(forAddressString: "00-11-22-33-44-55-66"))
        XCTAssertNil(BluetoothDeviceIdentifier.identifier(forAddressString: "zz-11-22-33-44-55"))
        XCTAssertNil(BluetoothDeviceIdentifier.identifier(forAddressString: "AirPods"))
    }

    func testAnUnrelatedUUIDCarriesNoAddress() {
        // A v4 UUID, e.g. the CoreBluetooth-era `CBPeripheral.identifier`
        // this replaced: there is no address to recover, and the gateway
        // reports `unrecognizedDeviceIdentifier` rather than guessing.
        let unrelated = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        XCTAssertNil(BluetoothDeviceIdentifier.addressString(for: unrelated))
    }

    func testIdentifiersAreWellFormedVersion8UUIDs() {
        // RFC 9562 reserves version 8 for vendor-specific layouts like
        // this one, so a thrw identifier can never collide with a
        // randomly generated v4 identifier.
        let identifier = BluetoothDeviceIdentifier.identifier(forAddressString: "00-11-22-33-44-55")
        let fields = identifier?.uuidString.lowercased().split(separator: "-")

        XCTAssertEqual(fields?.count, 5)
        XCTAssertEqual(fields?[2].first, "8")
        XCTAssertEqual(fields?[3].first, "8")
    }
}
