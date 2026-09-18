import Foundation

/// Validation + normalization of what a human enters in the provisioning
/// window (#143). Swift mirror of `adapter-android`'s
/// `identity/ProvisioningInput.kt`, and pure Swift for the same reason
/// that one is pure Kotlin: the window around it can't be unit tested,
/// but this can.
///
/// Validating at all - rather than persisting raw strings - matters
/// because both values are read later by a menu-bar app with no good way
/// to report a typo: a stray space in the account id silently produces a
/// topic nobody is subscribed to, and a malformed headset address makes
/// ``BluetoothDeviceIdentifier/identifier(forAddressString:)`` return nil
/// long after the window is gone, leaving the node silently unprovisioned.
public enum ProvisioningInput {
    /// Why a field was rejected. A case rather than a message string, so
    /// this type stays free of any UI/localization dependency - the
    /// window maps each case to human text.
    public enum FieldError: Equatable, Sendable {
        case accountIdBlank
        case accountIdUnsupportedCharacters
        case headsetAddressBlank
        case headsetAddressMalformed
    }

    /// Outcome of validating one field. The `valid` payload is the
    /// *normalized* value to persist - not necessarily what was typed.
    public enum FieldResult: Equatable, Sendable {
        case valid(String)
        case invalid(FieldError)
    }

    /// Account ids are topic-safe ASCII: letters, digits, `.`, `_`, `-`,
    /// up to 64 characters - byte-identical to `ProvisioningInput.kt`'s
    /// own `ACCOUNT_ID` regex, deliberately, since the same value has to
    /// address the same MQTT topics from either platform.
    ///
    /// No canonical account-id format exists anywhere in this repo yet
    /// (`services/licensing`, which will mint them, isn't built), so this
    /// checks only what the protocol itself requires rather than
    /// inventing a shape licensing might contradict later: the value is
    /// interpolated straight into every topic (`thrw/{account}/...`, see
    /// ``Topics`` and architecture.md), so `/`, the `+`/`#` wildcards,
    /// whitespace and non-ASCII are rejected.
    /// A plain character-set check rather than a regex: it expresses the
    /// same rule, needs no bare-slash-literal language mode, and has no
    /// regex-engine availability question on any platform this package
    /// compiles for.
    private static let allowedAccountIdCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    private static let maxAccountIdLength = 64

    /// Validates a typed account id, trimming surrounding whitespace.
    public static func accountId(_ raw: String) -> FieldResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .invalid(.accountIdBlank) }
        guard trimmed.count <= maxAccountIdLength,
              trimmed.unicodeScalars.allSatisfy(allowedAccountIdCharacters.contains)
        else {
            return .invalid(.accountIdUnsupportedCharacters)
        }
        return .valid(trimmed)
    }

    /// Validates a headset Bluetooth address and normalizes it to the
    /// dash-separated form `IOBluetoothDevice.addressString` itself uses
    /// (`00-11-22-33-44-55`).
    ///
    /// Unlike Android's equivalent, this accepts any separator style
    /// (`:`, `-`, or none) rather than requiring colons, because that is
    /// exactly what ``BluetoothDeviceIdentifier`` already accepts - and
    /// because on this platform the address normally arrives from the
    /// paired-device picker rather than a keyboard, in IOBluetooth's own
    /// dash form. Validation is delegated to
    /// ``BluetoothDeviceIdentifier`` rather than duplicating a regex, so
    /// there is exactly one definition of "an address this adapter can
    /// actually resolve".
    public static func headsetAddress(_ raw: String) -> FieldResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .invalid(.headsetAddressBlank) }
        guard let identifier = BluetoothDeviceIdentifier.identifier(forAddressString: trimmed),
              let normalized = BluetoothDeviceIdentifier.addressString(for: identifier)
        else {
            return .invalid(.headsetAddressMalformed)
        }
        return .valid(normalized)
    }
}
