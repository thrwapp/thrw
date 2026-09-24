import Foundation

/// ``MutedVolumeStore`` backed by `UserDefaults`, so the muted device and
/// its pre-mute volume survive the process dying mid-handover - which is
/// the whole point of storing them (ADR 0022's 2026-09-23 amendment).
///
/// Keys are namespaced like ``UserDefaultsSequenceStore``'s and
/// `AdapterProvisioning`'s, so everything this adapter stores shows up in
/// one `defaults read app.thrw.mac`. That matters more here than
/// elsewhere: these are the keys someone reads to answer "why is my
/// volume at zero", and the answer needs to be findable.
///
/// Two keys rather than one since #282: the volume alone is not enough to
/// restore anything, because it does not say *which device* was muted.
public final class UserDefaultsMutedVolumeStore: MutedVolumeStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MutedOutput? {
        // `object(forKey:)` rather than `float(forKey:)`: the latter
        // returns 0 for a missing key, and 0 is exactly the value that
        // would restore the user to silence. Absence and zero must not
        // read the same - the same trap `UserDefaultsSequenceStore`
        // documents for sequence numbers.
        guard let stored = defaults.object(forKey: Self.volumeKey) as? Float else { return nil }
        // Both halves or neither. A volume with no device is a record
        // nothing can act on, and honouring it would send the restore
        // back to guessing at the current default output - the bug #282
        // exists to remove. A record left by a pre-#282 build therefore
        // reads as absent, which is the right answer: it cannot be
        // honoured, and whatever device it muted has since been set by
        // hand or by macOS remembering its own per-device level.
        guard let uid = defaults.string(forKey: Self.deviceKey) else { return nil }
        return MutedOutput(uid: uid, volume: stored)
    }

    public func save(_ muted: MutedOutput) {
        defaults.set(muted.volume, forKey: Self.volumeKey)
        defaults.set(muted.uid, forKey: Self.deviceKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.volumeKey)
        defaults.removeObject(forKey: Self.deviceKey)
    }

    private static let volumeKey = "app.thrw.mac.handoverAudio.preMuteVolume"
    private static let deviceKey = "app.thrw.mac.handoverAudio.preMuteDeviceUID"
}
