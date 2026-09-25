import Foundation

/// Where the paused flag survives a restart (#290).
///
/// A protocol rather than `UserDefaults` directly, the same seam
/// ``SequenceStore`` and ``MutedVolumeStore`` use, so the pause logic is
/// testable without touching the user's real defaults.
public protocol ArbitrationPauseStore: Sendable {
    func isPaused() -> Bool
    func setPaused(_ paused: Bool)
}

/// For tests, and for a node built without persistence.
public final class InMemoryArbitrationPauseStore: ArbitrationPauseStore, @unchecked Sendable {
    private let lock = NSLock()
    private var paused: Bool

    public init(paused: Bool = false) {
        self.paused = paused
    }

    public func isPaused() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    public func setPaused(_ paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.paused = paused
    }
}

/// ``ArbitrationPauseStore`` backed by `UserDefaults`.
///
/// Durable because the situation it exists for outlasts the process:
/// #290 criterion 3. The Mac relaunches at every login (#144), and a
/// pause that quietly forgot itself would hand the headset back mid-call
/// — the exact failure the pause was turned on to prevent.
public final class UserDefaultsArbitrationPauseStore: ArbitrationPauseStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isPaused() -> Bool {
        defaults.bool(forKey: Self.key)
    }

    public func setPaused(_ paused: Bool) {
        defaults.set(paused, forKey: Self.key)
    }

    /// Namespaced like every other key this adapter writes, so it shows
    /// up in one `defaults read app.thrw.mac` — which is where someone
    /// will look when switching has "stopped working".
    private static let key = "app.thrw.mac.arbitrationPaused"
}

/// "Leave my headset alone on this device" (#290).
///
/// ## Why this exists
///
/// thrw arbitrates between the devices it manages. A device without an
/// adapter — a locked-down work laptop, most commonly — is invisible to
/// it, so a trigger on a managed device wins against a call happening on
/// the unmanaged one. #287 is that, reported from real use: a phone
/// taking the headset off a laptop call, repeatedly.
///
/// #289 bounded the repetition. It cannot stop the first claim, because
/// from the relay's point of view nothing else is using the headset.
/// This is the escape hatch: the user knows they are on a call even when
/// thrw structurally cannot.
///
/// ## Why suppressing emission is enough
///
/// A paused node publishes no triggers, so it has nothing to win
/// arbitration with and the relay has no reason to claim it. Commands
/// are still honoured — pausing means "stop grabbing", not "go deaf".
///
/// The tempting alternative, ignoring commands, is wrong: it leaves the
/// relay believing this node holds a resource it does not, which is the
/// drift #287 was about. Better not to manufacture that state
/// deliberately.
public final class ArbitrationPause: @unchecked Sendable {
    private let store: ArbitrationPauseStore
    private let node: EventLifecycle

    public init(node: EventLifecycle, store: ArbitrationPauseStore = InMemoryArbitrationPauseStore()) {
        self.node = node
        self.store = store
    }

    public func isPaused() -> Bool {
        store.isPaused()
    }

    /// Pauses if running, resumes if paused. Returns the new state.
    ///
    /// Pausing **ends this node's active triggers**, published, rather
    /// than only suppressing future ones (#290 criterion 2). Suppressing
    /// alone would leave the relay counting signals this node has
    /// stopped reporting, so a paused holder would keep the headset
    /// until something else outranked it — which is precisely the
    /// situation the user is trying to escape.
    ///
    /// The flag is set **before** ending, so a failure part-way through
    /// leaves the node paused rather than half-paused: the next
    /// registration carries the shrunken `activeEvents` and the relay
    /// reconciles (#178). The opposite order could leave triggers ended
    /// on a node that is still emitting.
    @discardableResult
    public func toggle() async throws -> Bool {
        let wantToPause = !isPaused()
        store.setPaused(wantToPause)
        if wantToPause {
            for type in node.activeEventKinds() {
                try await node.endEvent(type: type)
            }
        }
        return wantToPause
    }
}
