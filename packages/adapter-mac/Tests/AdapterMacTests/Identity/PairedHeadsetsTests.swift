import XCTest

@testable import AdapterMac

/// Fakes the ``PairedDeviceSource`` boundary - the real
/// `IOBluetoothPairedDeviceSource` can't run here (no Bluetooth hardware
/// on CI), same discipline `FakeBluetoothPeripheralGateway` follows.
private struct FakePairedDeviceSource: PairedDeviceSource {
    let result: [PairedDevice]?
    func pairedDevices() -> [PairedDevice]? { result }
}

final class PairedHeadsetsTests: XCTestCase {
    private let airpods = PairedDevice(name: "Tom's AirPods Pro", address: "aa-bb-cc-dd-ee-ff")
    private let unnamed = PairedDevice(name: nil, address: "11-22-33-44-55-66")

    /// "Bluetooth is off" and "nothing is paired" both surface as an
    /// empty list from IOBluetooth, but they need different explanations
    /// in the picker - an empty picker with no reason is the failure mode
    /// #117 called out on the Android side.
    func testAnUnreadableListIsBluetoothUnavailableNotAnEmptyPicker() {
        XCTAssertEqual(PairedHeadsets.state(pairedDevices: nil), .bluetoothUnavailable)
    }

    func testAnEmptyListIsNoDevicesPaired() {
        XCTAssertEqual(PairedHeadsets.state(pairedDevices: []), .noDevicesPaired)
    }

    func testDevicesArePresentedInThePlatformsOwnOrder() {
        XCTAssertEqual(
            PairedHeadsets.state(pairedDevices: [airpods, unnamed]),
            .devices([airpods, unnamed])
        )
    }

    func testTheSourceIsWhatDrivesTheState() {
        let source = FakePairedDeviceSource(result: [airpods])
        XCTAssertEqual(PairedHeadsets.state(pairedDevices: source.pairedDevices()), .devices([airpods]))
    }

    /// Class majors below are the real values read off a Mac with 10
    /// paired devices - see `isSelectableHeadset`'s own doc.
    func testOnlyAudioClassDevicesAreOfferedAsHeadsets() {
        // 0x04 - AirPods Pro, AirPods Max, Pixel Buds Pro 2, WH-1000XM6.
        XCTAssertTrue(PairedHeadsets.isSelectableHeadset(majorDeviceClass: 0x04))
        // 0x05 - Magic Keyboard, Magic Trackpad.
        XCTAssertFalse(PairedHeadsets.isSelectableHeadset(majorDeviceClass: 0x05))
        // 0x00 - MX Master mouse, a paired iPad.
        XCTAssertFalse(PairedHeadsets.isSelectableHeadset(majorDeviceClass: 0x00))
    }

    func testTheAudioMajorClassMatchesBluetoothsOwnConstant() {
        // kBluetoothDeviceClassMajorAudio, spelled out here so this rule
        // stays testable without importing IOBluetooth.
        XCTAssertEqual(PairedHeadsets.audioMajorDeviceClass, 4)
    }

    func testALabelCombinesNameAndAddress() {
        XCTAssertEqual(PairedHeadsets.label(for: airpods), "Tom's AirPods Pro (aa-bb-cc-dd-ee-ff)")
    }

    /// `IOBluetoothDevice.name` is optional, and a whitespace-only name
    /// would render as a blank picker row.
    func testALabelFallsBackToTheAddressWhenThereIsNoUsableName() {
        XCTAssertEqual(PairedHeadsets.label(for: unnamed), "11-22-33-44-55-66")
        XCTAssertEqual(
            PairedHeadsets.label(for: PairedDevice(name: "   ", address: "11-22-33-44-55-66")),
            "11-22-33-44-55-66"
        )
    }
}
