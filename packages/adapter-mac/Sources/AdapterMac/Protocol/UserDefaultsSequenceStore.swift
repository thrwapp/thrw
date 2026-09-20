import Foundation

/// ``SequenceStore`` backed by `UserDefaults`, so the high-water mark
/// survives the app quitting and relaunching - which it does on every
/// login, since `SMAppServiceLoginItem` (#144) starts it at boot.
///
/// That durability is acceptance criterion 3: the broker may redeliver a
/// QoS 1 command to the reconnecting node, and an in-memory mark would
/// have forgotten that the command was already acted on.
///
/// Keys are namespaced the same way `AdapterProvisioning`'s are, so
/// everything this adapter stores is identifiable in one `defaults read
/// app.thrw.mac`.
public final class UserDefaultsSequenceStore: SequenceStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(resource: String) -> SequenceMark? {
        guard let epoch = defaults.string(forKey: Self.epochKey(resource)) else { return nil }
        // `object(forKey:)` rather than `integer(forKey:)`: the latter
        // returns 0 for a missing key, and 0 is a legitimate-looking
        // sequence number. Absence and zero must not read the same.
        guard let seq = defaults.object(forKey: Self.seqKey(resource)) as? Int else { return nil }
        return SequenceMark(epoch: epoch, seq: seq)
    }

    public func save(resource: String, mark: SequenceMark) {
        defaults.set(mark.epoch, forKey: Self.epochKey(resource))
        defaults.set(mark.seq, forKey: Self.seqKey(resource))
    }

    private static func epochKey(_ resource: String) -> String {
        "app.thrw.mac.commandSequence.\(resource).epoch"
    }

    private static func seqKey(_ resource: String) -> String {
        "app.thrw.mac.commandSequence.\(resource).seq"
    }
}
