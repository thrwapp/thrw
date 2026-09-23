import Foundation

/// Where a ``MutingHandoverAudioGate`` keeps the volume it muted *from*,
/// across process restarts.
///
/// Durable rather than in-memory for one reason, and it is the reason
/// ADR 0022's amendment makes the mitigation a requirement: if the
/// adapter dies between ``MutingHandoverAudioGate/silence()`` and
/// ``MutingHandoverAudioGate/restore()``, an in-memory record dies with
/// it and the user is left silently muted, with nothing on screen
/// explaining why and no way to guess that a headset switcher did it.
///
/// A protocol rather than `UserDefaults` directly, the same seam
/// ``SequenceStore`` uses, so the gate's logic is testable without
/// touching the user's real defaults.
public protocol MutedVolumeStore: Sendable {
    /// The pre-mute volume, or `nil` if this node is not currently
    /// holding one - meaning it did not mute, or it already restored.
    func load() -> Float?
    func save(_ volume: Float)
    func clear()
}

/// For tests, and for a gate built without persistence.
public final class InMemoryMutedVolumeStore: MutedVolumeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var volume: Float?

    public init() {}

    public func load() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return volume
    }

    public func save(_ volume: Float) {
        lock.lock()
        defer { lock.unlock() }
        self.volume = volume
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        volume = nil
    }
}

/// ``HandoverAudioGate`` that drops the output volume to zero across the
/// handover window and puts it back afterwards (ADR 0022, #254).
///
/// Swift counterpart of `adapter-android`'s
/// `MediaSessionHandoverAudioGate`, but deliberately a *different
/// mechanism*: Android pauses the media session, macOS mutes. See
/// ``HandoverAudioGate`` for why - the short version is that pausing on
/// macOS needs an Accessibility grant that dies on every build of an
/// ad-hoc signed app. Muting needs no permission at all.
///
/// ## Muting is the riskier of the two, so the rules are stricter
///
/// A pause that never gets un-paused is visible and obviously fixable -
/// the user presses play. A mute that never gets un-muted is neither:
/// audio simply stops working, with no indication that this app is
/// responsible. Three rules follow, and all three are tested:
///
/// 1. **Persist before muting, never after.** A crash between the two
///    writes must leave a record and an un-muted device, not a muted
///    device and no record.
/// 2. **Never overwrite an existing record.** A second ``silence()``
///    without an intervening ``restore()`` would otherwise persist `0`
///    as the "pre-mute" volume and restore the user to silence.
/// 3. **Recover on startup.** ``restoreAfterPreviousRun()`` runs at
///    adapter launch, so a crash inside the window self-heals on next
///    launch. This is what makes rule 1 worth anything.
///
/// One gap those rules do **not** close: a Mac that releases and is
/// never claimed again stays muted for the rest of the session, and
/// nothing on screen says so. That is ADR 0022's intended behaviour -
/// the audio moved to another device, playing it here is not what the
/// user wanted - but where Android's paused session is self-evident, a
/// mute is invisible. Making it visible in the menu bar is #265.
///
/// An actor because ``silence()`` and ``restore()`` are a read-modify-write
/// over the store, and the command loop is not the only thing that can
/// call them - startup recovery races with a command that arrives
/// immediately after launch.
public actor MutingHandoverAudioGate: HandoverAudioGate {
    private let volume: SystemOutputVolume
    private let store: MutedVolumeStore

    public init(volume: SystemOutputVolume, store: MutedVolumeStore) {
        self.volume = volume
        self.store = store
    }

    public func silence() async {
        // Rule 2. Already holding a record means a previous silence()
        // has not been restored yet; the volume is already 0 and the
        // record we hold is the one worth keeping.
        guard store.load() == nil else { return }

        // Unreadable volume - a device exposing volume per-channel
        // rather than on the main element - means we cannot promise to
        // put it back. Leaking audio for 2.7s is the better failure
        // than muting a device we do not know how to un-mute.
        guard let current = volume.current() else {
            logAdapterError(category: "HandoverAudioGate", "output volume unreadable; not muting for handover")
            return
        }

        // Already silent: nothing to suppress, and persisting 0 would
        // make restore() a no-op that looks like a successful one.
        guard current > 0 else { return }

        // Rule 1: the record first, the mute second.
        store.save(current)
        volume.set(0)
    }

    public func restore() async {
        guard let muted = store.load() else { return }
        volume.set(muted)
        store.clear()
    }

    /// Rule 3. Call once at adapter startup, before any command is
    /// handled.
    ///
    /// Finding a record here means the previous run left this Mac muted.
    /// Two ways that happens, and un-muting is right for both:
    ///
    /// - The process died inside a handover window - the crash case the
    ///   ADR's amendment is about.
    /// - It released the headset and was never claimed again, so the
    ///   record was still legitimately held at quit. ``silence()`` on
    ///   release deliberately has no matching restore (see
    ///   ``HandoverAudioGate``), which means a released Mac stays muted
    ///   until it is claimed again. Carrying that across a *relaunch*
    ///   would be indistinguishable from a bug, so it does not.
    ///
    /// Logged either way: this line is the only trace that the user's
    /// volume was ever touched, and without it a bug report reads "my
    /// volume changed by itself".
    public func restoreAfterPreviousRun() async {
        guard let muted = store.load() else { return }
        logAdapterInfo(
            category: "HandoverAudioGate",
            "restoring output volume to \(muted) - previous run left it muted for a handover"
        )
        volume.set(muted)
        store.clear()
    }
}
