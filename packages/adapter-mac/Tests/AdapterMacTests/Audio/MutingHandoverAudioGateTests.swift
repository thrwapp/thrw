import XCTest

@testable import AdapterMac

private let speakers = "BuiltInSpeakerDevice"
private let headset = "AirPods-UID"

/// Fakes the CoreAudio boundary, keyed by device UID, so the gate's rules
/// are testable without audio hardware.
///
/// Device-keyed since #282, and that is the whole point: the real bug was
/// the gate muting one device and restoring another, which a fake with a
/// single global volume could not express — and therefore could not
/// catch.
private final class FakeSystemOutputVolume: SystemOutputVolume, @unchecked Sendable {
    private let lock = NSLock()
    private var volumes: [String: Float]
    private var unreadable: Set<String> = []
    private(set) var writes: [(uid: String, volume: Float)] = []

    /// Which device is currently the default output. Settable, because a
    /// handover changes it mid-window — the condition under test.
    var defaultUID: String?

    init(volumes: [String: Float], defaultUID: String?) {
        self.volumes = volumes
        self.defaultUID = defaultUID
    }

    /// Marks a device as reporting no main-element volume — what the
    /// reference AirPods actually do (#282).
    func makeUnreadable(_ uid: String) {
        unreadable.insert(uid)
    }

    func level(_ uid: String) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return volumes[uid]
    }

    func defaultOutputUID() -> String? { defaultUID }

    func volume(forUID uid: String) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return unreadable.contains(uid) ? nil : volumes[uid]
    }

    func setVolume(_ volume: Float, forUID uid: String) {
        lock.lock()
        defer { lock.unlock() }
        writes.append((uid, volume))
        // An unsettable device swallows the write, exactly as the real
        // headset does.
        guard !unreadable.contains(uid) else { return }
        volumes[uid] = volume
    }
}

final class MutingHandoverAudioGateTests: XCTestCase {
    private func gateAndVolume(
        speakerLevel: Float = 0.42,
        defaultUID: String? = speakers
    ) -> (MutingHandoverAudioGate, FakeSystemOutputVolume, InMemoryMutedVolumeStore) {
        let volume = FakeSystemOutputVolume(
            volumes: [speakers: speakerLevel, headset: 0.8],
            defaultUID: defaultUID
        )
        volume.makeUnreadable(headset)
        let store = InMemoryMutedVolumeStore()
        return (MutingHandoverAudioGate(volume: volume, store: store), volume, store)
    }

    func testSilenceDropsTheVolumeToZeroAndRestorePutsItBack() async {
        let (gate, volume, _) = gateAndVolume(speakerLevel: 0.42)

        await gate.silence()
        XCTAssertEqual(volume.level(speakers), 0)

        await gate.restore()
        XCTAssertEqual(volume.level(speakers), 0.42)
    }

    // MARK: - the device the mute was applied to (#282)

    /// The bug this change exists for. During a claim the headset becomes
    /// the default output *between* silence and restore, so a gate that
    /// re-resolves "the default device" restores the wrong one — and
    /// leaves the speakers at zero with the record already consumed.
    func testRestoreTargetsTheMutedDeviceEvenAfterTheDefaultOutputChanges() async {
        let (gate, volume, store) = gateAndVolume(speakerLevel: 0.42)

        await gate.silence()
        XCTAssertEqual(volume.level(speakers), 0)

        // The headset finishes connecting and takes over as default.
        volume.defaultUID = headset

        await gate.restore()

        XCTAssertEqual(volume.level(speakers), 0.42, "the speakers must be the device restored")
        XCTAssertNil(store.load())
        XCTAssertFalse(
            volume.writes.contains { $0.uid == headset },
            "nothing should ever be written to a device that was not muted"
        )
    }

    /// The record has to name the device, or the above cannot be done at
    /// all. Asserted on the stored value rather than only on behaviour,
    /// because this is the thing that has to survive a crash.
    func testTheRecordNamesTheDeviceItMuted() async {
        let (gate, _, store) = gateAndVolume(speakerLevel: 0.6)

        await gate.silence()

        XCTAssertEqual(store.load(), MutedOutput(uid: speakers, volume: 0.6))
    }

    /// The reference AirPods report no main-element volume at all, so the
    /// release path — where the headset is still the default output —
    /// cannot mute, and must not pretend otherwise (#282).
    func testAHeadsetThatReportsNoVolumeIsNotMuted() async {
        let (gate, volume, store) = gateAndVolume(defaultUID: headset)

        await gate.silence()

        XCTAssertTrue(volume.writes.isEmpty)
        XCTAssertNil(store.load())
    }

    /// Rule 1. A crash between the two writes must leave a record and an
    /// un-muted device, never a muted device and no record — the second
    /// is unrecoverable, because nothing then knows what to restore to.
    func testTheVolumeIsPersistedBeforeItIsMuted() async {
        let (gate, volume, store) = gateAndVolume(speakerLevel: 0.6)

        await gate.silence()

        XCTAssertEqual(store.load()?.volume, 0.6)
        XCTAssertEqual(volume.writes.count, 1, "exactly one write, and the record was in place before it")
        XCTAssertEqual(volume.writes.first?.volume, 0)
    }

    /// Rule 2, and the bug it prevents is the nastiest here: a second
    /// `silence()` that overwrote the record would persist `0` as the
    /// "pre-mute" volume, and the eventual restore would set the user's
    /// Mac to silence and clear the only evidence of the original.
    ///
    /// Not hypothetical: a release silences without restoring, so the
    /// very next claim calls `silence()` on a gate already holding a
    /// record. That is the normal handover sequence, not an edge case.
    func testASecondSilenceDoesNotOverwriteTheRecordedVolume() async {
        let (gate, volume, store) = gateAndVolume(speakerLevel: 0.75)

        await gate.silence()
        await gate.silence()
        await gate.restore()

        XCTAssertEqual(volume.level(speakers), 0.75)
        XCTAssertNil(store.load())
    }

    /// The release-then-claim sequence above, end to end.
    func testAReleaseThenAClaimRestoresTheOriginalVolumeRatherThanZero() async {
        let (gate, volume, _) = gateAndVolume(speakerLevel: 0.3)

        await gate.silence()  // release: silence, no restore
        await gate.silence()  // the claim that follows
        await gate.restore()

        XCTAssertEqual(volume.level(speakers), 0.3)
    }

    /// Persisting `0` here would make the later `restore()` a no-op that
    /// looks like a successful one, and would consume the record a real
    /// mute needed.
    func testAnAlreadySilentDeviceIsNotRecorded() async {
        let (gate, volume, store) = gateAndVolume(speakerLevel: 0)

        await gate.silence()

        XCTAssertNil(store.load())
        XCTAssertTrue(volume.writes.isEmpty)
    }

    /// `restore()` must not start audio that was not suppressed — it is
    /// called on outcome paths that may never have reached a `silence()`.
    func testRestoreWithoutASilenceChangesNothing() async {
        let (gate, volume, _) = gateAndVolume(speakerLevel: 0.9)

        await gate.restore()

        XCTAssertTrue(volume.writes.isEmpty)
        XCTAssertEqual(volume.level(speakers), 0.9)
    }

    // MARK: - reporting the mute so it is not invisible (#265)

    func testAGateThatHasNotMutedReportsNoSuppression() async {
        let (gate, _, _) = gateAndVolume()

        let suppressing = await gate.isSuppressing()

        XCTAssertFalse(suppressing)
    }

    func testAMutedGateReportsSuppressionUntilItIsRestored() async {
        let (gate, _, _) = gateAndVolume()

        await gate.silence()
        var suppressing = await gate.isSuppressing()
        XCTAssertTrue(suppressing)

        await gate.restore()
        suppressing = await gate.isSuppressing()
        XCTAssertFalse(suppressing, "#265 criterion 3 - the indicator clears when the mute is undone")
    }

    /// A device whose volume could not be read is never muted, so it must
    /// not claim to be suppressing either — otherwise the menu offers an
    /// un-mute for something that was never muted.
    func testAGateThatDeclinedToMuteReportsNoSuppression() async {
        let (gate, _, _) = gateAndVolume(defaultUID: headset)

        await gate.silence()

        let suppressing = await gate.isSuppressing()
        XCTAssertFalse(suppressing)
    }

    /// #265 criterion 4. A node built without a real gate shows no
    /// indicator and behaves exactly as it did before.
    func testTheNoOpGateNeverReportsSuppression() async {
        let gate = NoOpHandoverAudioGate()

        await gate.silence()

        let suppressing = await gate.isSuppressing()
        XCTAssertFalse(suppressing)
    }

    // MARK: - crash recovery (ADR 0022's amendment)

    /// Rule 3, and the requirement ADR 0022's amendment calls
    /// non-optional: a process that died inside the handover window must
    /// not leave the user silently muted with no explanation.
    ///
    /// Simulated the only way it can be: a *new* gate over the store the
    /// dead one left behind, which is exactly what a relaunch produces.
    func testAStoreLeftBehindByAPreviousRunIsRestoredAtStartup() async {
        let store = InMemoryMutedVolumeStore()
        let crashedVolume = FakeSystemOutputVolume(volumes: [speakers: 0.55], defaultUID: speakers)
        await MutingHandoverAudioGate(volume: crashedVolume, store: store).silence()

        // The relaunch: a fresh gate over the same durable store,
        // inheriting a muted device — and, to make the point, a
        // different default output than the one that was muted.
        let volume = FakeSystemOutputVolume(volumes: [speakers: 0, headset: 0.8], defaultUID: headset)
        volume.makeUnreadable(headset)
        await MutingHandoverAudioGate(volume: volume, store: store).restoreAfterPreviousRun()

        XCTAssertEqual(volume.level(speakers), 0.55)
        XCTAssertNil(store.load(), "the record must be consumed, or the next restore would fight the user")
    }

    /// A record naming a device that is no longer present must be cleared
    /// rather than carried forever — and must not write to anything,
    /// which is why the identifier is a stable UID and not an
    /// `AudioDeviceID` that could by then name a different device.
    func testARecordForADeviceThatIsGoneIsClearedWithoutWritingAnything() async {
        let store = InMemoryMutedVolumeStore()
        store.save(MutedOutput(uid: "device-that-was-unplugged", volume: 0.4))
        let volume = FakeSystemOutputVolume(volumes: [speakers: 0.25], defaultUID: speakers)

        await MutingHandoverAudioGate(volume: volume, store: store).restoreAfterPreviousRun()

        XCTAssertEqual(volume.level(speakers), 0.25, "an unrelated device must not be touched")
        XCTAssertNil(store.load())
    }

    /// The ordinary launch, which is almost every launch.
    func testStartupRecoveryDoesNothingWhenNoRecordWasLeft() async {
        let (gate, volume, _) = gateAndVolume(speakerLevel: 0.8)

        await gate.restoreAfterPreviousRun()

        XCTAssertTrue(volume.writes.isEmpty)
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

    func testARecordSurvivesANewStoreOverTheSameDefaults() {
        UserDefaultsMutedVolumeStore(defaults: defaults).save(MutedOutput(uid: speakers, volume: 0.35))

        XCTAssertEqual(
            UserDefaultsMutedVolumeStore(defaults: defaults).load(),
            MutedOutput(uid: speakers, volume: 0.35)
        )
    }

    func testClearingLeavesNothingBehind() {
        let store = UserDefaultsMutedVolumeStore(defaults: defaults)
        store.save(MutedOutput(uid: speakers, volume: 0.35))
        store.clear()

        XCTAssertNil(store.load())
    }

    /// The distinction `float(forKey:)` would destroy. A device muted from
    /// an already-zero volume never gets recorded, so a stored `0` should
    /// not exist — but if one ever does, it must read as a stored value
    /// rather than as absence, or the two become indistinguishable in a
    /// bug report.
    func testAStoredZeroIsNotMistakenForAnEmptyStore() {
        let store = UserDefaultsMutedVolumeStore(defaults: defaults)
        store.save(MutedOutput(uid: speakers, volume: 0))

        XCTAssertEqual(store.load(), MutedOutput(uid: speakers, volume: 0))
    }

    /// #282. A record written by a build that stored only a volume cannot
    /// be honoured — nothing says which device it belonged to — so it
    /// must read as absent rather than send the restore back to guessing
    /// at the current default output.
    func testAVolumeWithNoDeviceReadsAsAbsent() {
        defaults.set(Float(0.35), forKey: "app.thrw.mac.handoverAudio.preMuteVolume")

        XCTAssertNil(UserDefaultsMutedVolumeStore(defaults: defaults).load())
    }
}
