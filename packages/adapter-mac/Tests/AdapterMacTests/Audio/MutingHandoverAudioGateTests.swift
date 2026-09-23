import XCTest

@testable import AdapterMac

/// Fakes the CoreAudio boundary, so the gate's rules are testable
/// without audio hardware.
///
/// `readable = false` is the device that exposes volume per-channel
/// rather than on the main element - a real case, and the one where
/// muting would be unrecoverable.
private final class FakeSystemOutputVolume: SystemOutputVolume, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float
    private(set) var writes: [Float] = []
    var readable = true

    init(_ value: Float) { self.value = value }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func current() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return readable ? value : nil
    }

    func set(_ volume: Float) {
        lock.lock()
        defer { lock.unlock() }
        value = volume
        writes.append(volume)
    }
}

final class MutingHandoverAudioGateTests: XCTestCase {
    func testSilenceDropsTheVolumeToZeroAndRestorePutsItBack() async {
        let volume = FakeSystemOutputVolume(0.42)
        let gate = MutingHandoverAudioGate(volume: volume, store: InMemoryMutedVolumeStore())

        await gate.silence()
        XCTAssertEqual(volume.level, 0)

        await gate.restore()
        XCTAssertEqual(volume.level, 0.42)
    }

    /// Rule 1. A crash between the two writes must leave a record and an
    /// un-muted device, never a muted device and no record - the second
    /// is unrecoverable, because nothing then knows what to restore to.
    func testTheVolumeIsPersistedBeforeItIsMuted() async {
        let volume = FakeSystemOutputVolume(0.6)
        let store = InMemoryMutedVolumeStore()
        let gate = MutingHandoverAudioGate(volume: volume, store: store)

        await gate.silence()

        XCTAssertEqual(store.load(), 0.6)
        XCTAssertEqual(volume.writes, [0], "exactly one write, and the record was already in place before it")
    }

    /// Rule 2, and the bug it prevents is the nastiest one here: a second
    /// `silence()` that overwrote the record would persist `0` as the
    /// "pre-mute" volume, and the eventual restore would set the user's
    /// Mac to silence and clear the only evidence of the original.
    ///
    /// Not hypothetical: a release silences without restoring, so the
    /// very next claim calls `silence()` on a gate that is already
    /// holding a record. That is the normal handover sequence, not an
    /// edge case.
    func testASecondSilenceDoesNotOverwriteTheRecordedVolume() async {
        let volume = FakeSystemOutputVolume(0.75)
        let store = InMemoryMutedVolumeStore()
        let gate = MutingHandoverAudioGate(volume: volume, store: store)

        await gate.silence()
        await gate.silence()
        await gate.restore()

        XCTAssertEqual(volume.level, 0.75)
        XCTAssertNil(store.load())
    }

    /// The release-then-claim sequence above, end to end.
    func testAReleaseThenAClaimRestoresTheOriginalVolumeRatherThanZero() async {
        let volume = FakeSystemOutputVolume(0.3)
        let gate = MutingHandoverAudioGate(volume: volume, store: InMemoryMutedVolumeStore())

        await gate.silence()  // release: silence, no restore
        await gate.silence()  // the claim that follows
        await gate.restore()

        XCTAssertEqual(volume.level, 0.3)
    }

    /// Leaking audio for 2.7s is the better failure than muting a device
    /// we have no way to un-mute.
    func testAnUnreadableVolumeIsNotMuted() async {
        let volume = FakeSystemOutputVolume(0.5)
        volume.readable = false
        let store = InMemoryMutedVolumeStore()
        let gate = MutingHandoverAudioGate(volume: volume, store: store)

        await gate.silence()

        XCTAssertEqual(volume.writes, [])
        XCTAssertNil(store.load())
    }

    /// Persisting `0` here would make the later `restore()` a no-op that
    /// looks like a successful one, and would consume the record a real
    /// mute needed.
    func testAnAlreadySilentDeviceIsNotRecorded() async {
        let volume = FakeSystemOutputVolume(0)
        let store = InMemoryMutedVolumeStore()
        let gate = MutingHandoverAudioGate(volume: volume, store: store)

        await gate.silence()

        XCTAssertNil(store.load())
        XCTAssertEqual(volume.writes, [])
    }

    /// `restore()` must not start audio that was not suppressed - it is
    /// called on outcome paths that may never have reached a `silence()`.
    func testRestoreWithoutASilenceChangesNothing() async {
        let volume = FakeSystemOutputVolume(0.9)
        let gate = MutingHandoverAudioGate(volume: volume, store: InMemoryMutedVolumeStore())

        await gate.restore()

        XCTAssertEqual(volume.writes, [])
        XCTAssertEqual(volume.level, 0.9)
    }

    /// Rule 3, and the requirement ADR 0022's amendment calls
    /// non-optional: a process that died inside the handover window must
    /// not leave the user silently muted with no explanation.
    ///
    /// Simulated the only way it can be: a *new* gate over the store the
    /// dead one left behind, which is exactly what a relaunch produces.
    func testAStoreLeftBehindByAPreviousRunIsRestoredAtStartup() async {
        let store = InMemoryMutedVolumeStore()
        let crashed = MutingHandoverAudioGate(volume: FakeSystemOutputVolume(0.55), store: store)
        await crashed.silence()

        // The relaunch: a fresh gate, a fresh volume reading of 0 (the
        // muted device it inherited), the same durable store.
        let volume = FakeSystemOutputVolume(0)
        let relaunched = MutingHandoverAudioGate(volume: volume, store: store)
        await relaunched.restoreAfterPreviousRun()

        XCTAssertEqual(volume.level, 0.55)
        XCTAssertNil(store.load(), "the record must be consumed, or the next restore would fight the user")
    }

    /// The ordinary launch, which is almost every launch.
    func testStartupRecoveryDoesNothingWhenNoRecordWasLeft() async {
        let volume = FakeSystemOutputVolume(0.8)
        let gate = MutingHandoverAudioGate(volume: volume, store: InMemoryMutedVolumeStore())

        await gate.restoreAfterPreviousRun()

        XCTAssertEqual(volume.writes, [])
    }
}

final class UserDefaultsMutedVolumeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "app.thrw.mac.tests.mutedVolume"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testAnEmptyStoreReadsAsAbsentRatherThanZero() {
        XCTAssertNil(UserDefaultsMutedVolumeStore(defaults: defaults).load())
    }

    func testAVolumeSurvivesANewStoreOverTheSameDefaults() {
        UserDefaultsMutedVolumeStore(defaults: defaults).save(0.35)

        XCTAssertEqual(UserDefaultsMutedVolumeStore(defaults: defaults).load(), 0.35)
    }

    func testClearingLeavesNothingBehind() {
        let store = UserDefaultsMutedVolumeStore(defaults: defaults)
        store.save(0.35)
        store.clear()

        XCTAssertNil(store.load())
    }

    /// The distinction `float(forKey:)` would destroy. A device muted
    /// from an already-zero volume never gets recorded, so a stored `0`
    /// should not exist - but if one ever does, it must read as a stored
    /// value rather than as absence, or the two cases become
    /// indistinguishable in a bug report.
    func testAStoredZeroIsNotMistakenForAnEmptyStore() {
        let store = UserDefaultsMutedVolumeStore(defaults: defaults)
        store.save(0)

        XCTAssertEqual(store.load(), 0)
    }
}
