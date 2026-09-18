import Foundation

/// Which relay account this node belongs to, and which paired headset it
/// manages. Swift mirror of `adapter-android`'s
/// `identity/AdapterProvisioning.kt`.
///
/// Read by the app's composition root, which treats either being unset
/// as "not provisioned yet" and refuses to start a real ``MacNode``
/// rather than connecting a half-configured one - same honest failure
/// mode `AdapterForegroundService` uses on Android.
///
/// **No provisioning UI exists yet** (#128's own acceptance criterion 4
/// explicitly excludes building one) - there is currently no way to set
/// either value short of `UserDefaults`' `defaults write` command-line
/// tool. Mirrors the exact gap `docs/handoffs/96.md` documented for
/// Android before #102 added a real settings screen.
///
/// `headsetAddress` is a raw classic-Bluetooth address string (the same
/// shape `adapter-android`'s `headsetAddress` is, and the same shape a
/// future settings screen would collect from the user) rather than the
/// already-converted `UUID` ``MacNode`` needs - the string-to-identifier
/// conversion (``BluetoothDeviceIdentifier/identifier(forAddressString:)``)
/// happens at the composition root, alongside its own "not provisioned"
/// handling for a malformed address.
public enum AdapterProvisioning {
    private static let accountIdKey = "app.thrw.mac.adapterProvisioning.accountId"
    private static let headsetAddressKey = "app.thrw.mac.adapterProvisioning.headsetAddress"

    public static func accountId(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: accountIdKey)
    }

    public static func setAccountId(_ accountId: String, defaults: UserDefaults = .standard) {
        defaults.set(accountId, forKey: accountIdKey)
    }

    public static func headsetAddress(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: headsetAddressKey)
    }

    public static func setHeadsetAddress(_ headsetAddress: String, defaults: UserDefaults = .standard) {
        defaults.set(headsetAddress, forKey: headsetAddressKey)
    }
}
