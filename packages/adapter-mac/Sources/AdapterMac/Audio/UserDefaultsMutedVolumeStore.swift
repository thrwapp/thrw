import Foundation

/// ``MutedVolumeStore`` backed by `UserDefaults`, so the pre-mute volume
/// survives the process dying mid-handover - which is the whole point of
/// storing it (ADR 0022's 2026-09-23 amendment).
///
/// Key is namespaced like ``UserDefaultsSequenceStore``'s and
/// `AdapterProvisioning`'s, so everything this adapter stores shows up in
/// one `defaults read app.thrw.mac`. That matters more here than
/// elsewhere: this is the key someone reads to answer "why is my volume
/// at zero", and the answer needs to be findable.
public final class UserDefaultsMutedVolumeStore: MutedVolumeStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Float? {
        // `object(forKey:)` rather than `float(forKey:)`: the latter
        // returns 0 for a missing key, and 0 is exactly the value that
        // would restore the user to silence. Absence and zero must not
        // read the same - the same trap `UserDefaultsSequenceStore`
        // documents for sequence numbers.
        guard let stored = defaults.object(forKey: Self.key) as? Float else { return nil }
        return stored
    }

    public func save(_ volume: Float) {
        defaults.set(volume, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private static let key = "app.thrw.mac.handoverAudio.preMuteVolume"
}
