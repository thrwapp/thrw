import Foundation

/// Translates between the `UUID` device identifiers
/// ``BluetoothPeripheralGateway`` (and therefore
/// ``BluetoothConnectionManager``) speaks in and the classic-Bluetooth
/// MAC addresses `IOBluetoothDevice` speaks in.
///
/// Classic Bluetooth has no per-device UUID — CoreBluetooth's
/// `CBPeripheral.identifier` is a BLE-only, per-host-generated value,
/// and `IOBluetoothDevice` identifies a device solely by its 6-byte
/// address. Rather than widen the gateway protocol (whose `UUID`
/// signature the connection manager and its tests are written against),
/// the address is carried *inside* the identifier, losslessly:
///
///     74687277-6274-8000-8000-<6 address bytes>
///     └──"thrw"──┘└"bt"┘ └v8┘ └var┘
///
/// The fixed 10-byte prefix spells `thrwbt` and then sets RFC 9562's
/// version-8 ("vendor-specific format") and variant bits, so these are
/// well-formed UUIDs that can't collide with a random v4 one, and the
/// address stays readable in the last field. Because the mapping is
/// reversible, resolving an identifier back to a device needs no lookup
/// table and no persisted state.
public enum BluetoothDeviceIdentifier {
    /// `74687277-6274-8000-8000-` — see the type's documentation.
    static let identifierPrefix = "74687277-6274-8000-8000-"

    /// The identifier for the device at `addressString`, in any of the
    /// separator styles `IOBluetoothDevice` accepts (`00-11-22-33-44-55`,
    /// `00:11:22:33:44:55`, `001122334455`). `nil` if `addressString`
    /// isn't 6 hex-encoded bytes.
    public static func identifier(forAddressString addressString: String) -> UUID? {
        guard let hex = normalizedHex(forAddressString: addressString) else { return nil }
        return UUID(uuidString: identifierPrefix + hex)
    }

    /// The Bluetooth address encoded in `identifier`, formatted the way
    /// `IOBluetoothDevice.addressString` formats it
    /// (`00-11-22-33-44-55`). `nil` if `identifier` wasn't produced by
    /// ``identifier(forAddressString:)`` — an arbitrary UUID carries no
    /// address to recover.
    public static func addressString(for identifier: UUID) -> String? {
        let uuidString = identifier.uuidString.lowercased()
        guard uuidString.hasPrefix(identifierPrefix) else { return nil }
        let hex = String(uuidString.dropFirst(identifierPrefix.count))
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2)
            .map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return String(hex[start..<hex.index(start, offsetBy: 2)])
            }
            .joined(separator: "-")
    }

    /// `addressString` reduced to 12 lowercase hex digits with every
    /// separator removed, or `nil` if it isn't a Bluetooth address.
    /// Internal: callers outside this module work in identifiers, not
    /// addresses.
    static func normalizedHex(forAddressString addressString: String) -> String? {
        let stripped = addressString.filter { $0 != "-" && $0 != ":" && $0 != " " }
        guard stripped.count == 12, stripped.allSatisfy(\.isHexDigit) else { return nil }
        return stripped.lowercased()
    }
}
