import Foundation

/// One paired Bluetooth device, as much as the provisioning picker needs.
/// Pure-Swift mirror of the two `IOBluetoothDevice` fields the window
/// reads, kept free of `IOBluetooth` so the picker logic below is
/// unit-testable - same split as `adapter-android`'s `BondedDevice`.
public struct PairedDevice: Equatable, Sendable {
    public let name: String?
    public let address: String

    public init(name: String?, address: String) {
        self.name = name
        self.address = address
    }
}

/// What the provisioning window's headset picker should show. Mirrors
/// `adapter-android`'s `BondedHeadsetsState` (#117): "nothing paired" and
/// "Bluetooth unavailable" need explicit handling, not an empty picker
/// with no explanation.
public enum PairedHeadsetsState: Equatable, Sendable {
    /// Bluetooth is off, or the app can't enumerate devices - the real
    /// list can't be read at all, so an empty picker would be a lie.
    case bluetoothUnavailable
    /// Readable, but nothing is paired with this Mac yet.
    case noDevicesPaired
    /// At least one paired device, in the order the platform returned.
    case devices([PairedDevice])
}

/// Where the real paired-device list comes from. A protocol so the window
/// and the state logic can be exercised against a fake - the `IOBluetooth`
/// implementation can't run in a unit test (no Bluetooth hardware on CI,
/// same constraint `IOBluetoothPeripheralGateway` documents).
public protocol PairedDeviceSource: Sendable {
    /// Paired devices, or `nil` if the list can't be read at all
    /// (Bluetooth off/unavailable) - which is a different state from "no
    /// devices are paired", and the picker shows it differently.
    func pairedDevices() -> [PairedDevice]?
}

public enum PairedHeadsets {
    /// Bluetooth's "Audio" major device class (`kBluetoothDeviceClassMajorAudio`),
    /// spelled out rather than imported so this rule stays testable
    /// without `IOBluetooth`.
    public static let audioMajorDeviceClass: UInt32 = 0x04

    /// Whether a paired device should be offered as a headset.
    ///
    /// Verified against a real Mac's 10 paired devices: the four actual
    /// headsets (AirPods Pro, AirPods Max, Pixel Buds Pro 2, WH-1000XM6)
    /// all report major class `0x04`, while keyboards and trackpads
    /// report `0x05` and a mouse reports `0x00`. Without this filter the
    /// picker offers "Magic Trackpad" as a headset, which is worse than
    /// useless - selecting it would store an address the audio route can
    /// never move to.
    ///
    /// Known limitation: a headset that misreports its class (the same
    /// real Mac has two devices reporting `0x00`) is hidden entirely.
    /// That is the deliberate trade - a short, correct list beats a long
    /// list where most entries are wrong - but it is the first thing to
    /// revisit if a real headset ever fails to appear.
    public static func isSelectableHeadset(majorDeviceClass: UInt32) -> Bool {
        majorDeviceClass == audioMajorDeviceClass
    }

    /// Turns a raw lookup result into the state the picker renders. Fed
    /// in rather than read directly, the same fake-seam pattern
    /// `adapter-android`'s `BondedHeadsets.state` uses.
    public static func state(pairedDevices: [PairedDevice]?) -> PairedHeadsetsState {
        guard let pairedDevices else { return .bluetoothUnavailable }
        return pairedDevices.isEmpty ? .noDevicesPaired : .devices(pairedDevices)
    }

    /// The label shown per picker entry: `"name (00-11-22-33-44-55)"`, or
    /// just the address when the device reports no name
    /// (`IOBluetoothDevice.name` is optional).
    public static func label(for device: PairedDevice) -> String {
        guard let name = device.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return device.address
        }
        return "\(name) (\(device.address))"
    }
}
