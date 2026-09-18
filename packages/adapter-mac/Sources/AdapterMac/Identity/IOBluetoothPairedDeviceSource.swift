#if canImport(IOBluetooth)

import Foundation
import IOBluetooth

/// Real ``PairedDeviceSource``, reading `IOBluetoothDevice.pairedDevices()`
/// - the same call ``IOBluetoothPeripheralGateway`` already uses to
/// resolve a device before connecting it. Using the same source for both
/// is deliberate: the picker cannot offer a device the gateway would then
/// fail to resolve.
///
/// Not exercised by this package's tests - CI has no Bluetooth hardware,
/// so ``PairedHeadsets`` is tested against a fake at the
/// ``PairedDeviceSource`` boundary instead (same discipline
/// `IOBluetoothPeripheralGateway` documents for itself).
///
/// `pairedDevices()` returning an empty list is ambiguous on this API: it
/// means both "nothing is paired" and "Bluetooth is off". `IOBluetoothHostController`'s
/// power state disambiguates, so that's checked first and surfaced as the
/// distinct ``PairedHeadsetsState/bluetoothUnavailable`` case rather than
/// showing the user an empty picker with no explanation.
public struct IOBluetoothPairedDeviceSource: PairedDeviceSource {
    public init() {}

    public func pairedDevices() -> [PairedDevice]? {
        guard let controller = IOBluetoothHostController.default(),
              controller.powerState == kBluetoothHCIPowerStateON
        else {
            return nil
        }

        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { device in
            guard let address = device.addressString,
                  // Keyboards, trackpads and mice are paired too - see
                  // PairedHeadsets.isSelectableHeadset for why they're
                  // filtered out and what that costs.
                  PairedHeadsets.isSelectableHeadset(majorDeviceClass: device.deviceClassMajor)
            else {
                return nil
            }
            return PairedDevice(name: device.name, address: address)
        }
    }
}

#endif
