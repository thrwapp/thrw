import XCTest

@testable import AdapterMac

/// ADR 0018 decision 1 (#210), adapter half. Swift mirror of
/// `adapter-android`'s `CommandSequenceGateTest.kt` - the same cases in
/// the same order, so a rule fixed on one platform and missed on the
/// other shows up as a missing test rather than as a silent divergence.
///
/// Every test names a delivery the broker is actually entitled to make -
/// QoS 1 is at-least-once - rather than an abstract ordering property.
final class CommandSequenceGateTests: XCTestCase {
    private func claim(_ seq: Int?, _ epoch: String?) -> CommandPayload {
        CommandPayload(type: .claim, seq: seq, epoch: epoch)
    }

    private func release(_ seq: Int?, _ epoch: String?) -> CommandPayload {
        CommandPayload(type: .release, seq: seq, epoch: epoch)
    }

    func testAcceptsTheFirstCommandItEverSees() {
        XCTAssertTrue(CommandSequenceGate().accepts(claim(1, "e1")))
    }

    func testAcceptsACommandNewerThanTheMark() {
        let gate = CommandSequenceGate()
        gate.record(claim(1, "e1"))

        XCTAssertTrue(gate.accepts(release(2, "e1")))
    }

    /// The failure ADR 0018 names by hand: *"a stale claim arriving
    /// after a more recent release must not re-claim"*. Without the gate
    /// this takes the headset back from whichever device now holds it.
    func testDiscardsAClaimRedeliveredAfterANewerRelease() {
        let gate = CommandSequenceGate()
        gate.record(claim(4, "e1"))
        gate.record(release(5, "e1"))

        XCTAssertFalse(gate.accepts(claim(4, "e1")))
    }

    func testDiscardsAnExactDuplicate() {
        let gate = CommandSequenceGate()
        gate.record(claim(7, "e1"))

        XCTAssertFalse(gate.accepts(claim(7, "e1")))
    }

    /// Rule 2. Without this the system deadlocks after any relay
    /// restart: the relay's counters are in memory and go back to zero,
    /// while this node still holds a mark in the thousands.
    func testANewEpochResetsTheMark() {
        let gate = CommandSequenceGate()
        gate.record(claim(9_999, "e1"))

        XCTAssertTrue(gate.accepts(claim(1, "e2")))
    }

    func testAfterAnEpochChangeTheNewEpochsOwnOrderingApplies() {
        let gate = CommandSequenceGate()
        gate.record(claim(9_999, "e1"))
        gate.record(claim(1, "e2"))

        XCTAssertFalse(gate.accepts(claim(1, "e2")))
        XCTAssertTrue(gate.accepts(release(2, "e2")))
    }

    /// An epoch the node saw two epochs ago is not special-cased: the
    /// mark holds exactly one epoch, and anything not equal to it
    /// resets. Ordering across relay processes is not defined, so there
    /// is nothing better to do than trust the newest sender.
    func testReturningToAPreviouslySeenEpochAlsoResets() {
        let gate = CommandSequenceGate()
        gate.record(claim(5, "e1"))
        gate.record(claim(5, "e2"))

        XCTAssertTrue(gate.accepts(claim(1, "e1")))
    }

    func testAnUnsequencedCommandIsAcceptedAndRecordsNothing() {
        let store = InMemorySequenceStore()
        let gate = CommandSequenceGate(store: store)

        XCTAssertTrue(gate.accepts(claim(nil, nil)))
        gate.record(claim(nil, nil))

        XCTAssertNil(store.load(resource: resourceAudio))
    }

    func testACommandWithASeqButNoEpochIsAcceptedRatherThanCompared() {
        let gate = CommandSequenceGate()
        gate.record(claim(50, "e1"))

        XCTAssertTrue(gate.accepts(claim(1, nil)))
    }

    func testAnUnsequencedCommandDoesNotEraseAnExistingMark() {
        let store = InMemorySequenceStore()
        let gate = CommandSequenceGate(store: store)
        gate.record(claim(50, "e1"))

        gate.record(claim(nil, nil))

        XCTAssertEqual(SequenceMark(epoch: "e1", seq: 50), store.load(resource: resourceAudio))
    }

    /// `record` never moves the mark backwards, even if called with an
    /// older command. Nothing in `listenForCommands` does that today -
    /// `accepts` guards it - but the two are separate calls, and a mark
    /// that could be dragged back by a mis-sequenced call site would
    /// reopen the whole hole.
    func testRecordDoesNotMoveTheMarkBackwards() {
        let store = InMemorySequenceStore()
        let gate = CommandSequenceGate(store: store)
        gate.record(claim(9, "e1"))

        gate.record(claim(3, "e1"))

        XCTAssertEqual(SequenceMark(epoch: "e1", seq: 9), store.load(resource: resourceAudio))
    }

    func testAcceptsDoesNotMoveTheMark() {
        let store = InMemorySequenceStore()
        let gate = CommandSequenceGate(store: store)
        gate.record(claim(2, "e1"))

        XCTAssertTrue(gate.accepts(claim(3, "e1")))
        XCTAssertTrue(gate.accepts(claim(3, "e1")))
        XCTAssertEqual(SequenceMark(epoch: "e1", seq: 2), store.load(resource: resourceAudio))
    }

    /// Acceptance criterion 3. Two gates over one store is precisely
    /// what a process restart looks like from the store's point of view.
    func testTheMarkSurvivesAProcessRestart() {
        let store = InMemorySequenceStore()
        CommandSequenceGate(store: store).record(claim(11, "e1"))

        let afterRestart = CommandSequenceGate(store: store)

        XCTAssertFalse(afterRestart.accepts(claim(11, "e1")))
        XCTAssertTrue(afterRestart.accepts(claim(12, "e1")))
    }

    /// Acceptance criterion 4, half one: **this node** restarted while
    /// holding. The relay is the same process, so its counter kept
    /// climbing while the node was away, and the claim #173 re-asserts
    /// on registration carries a higher seq than the persisted mark.
    ///
    /// If this ever fails, #173 has regressed silently: a device that
    /// restarts while holding the headset goes back to being
    /// permanently stuck, with no command on the wire to show why.
    func test173sReAssertedClaimIsAcceptedAfterTheNodeRestarts() {
        let store = InMemorySequenceStore()
        CommandSequenceGate(store: store).record(claim(6, "e1"))

        XCTAssertTrue(CommandSequenceGate(store: store).accepts(claim(7, "e1")))
    }

    /// Acceptance criterion 4, half two: **the relay** restarted. Its
    /// counter is back at 1, far below this node's mark - and is
    /// accepted anyway, because the epoch changed. This is the case that
    /// would deadlock without the epoch.
    func test173sReAssertedClaimIsAcceptedAfterTheRelayRestarts() {
        let store = InMemorySequenceStore()
        CommandSequenceGate(store: store).record(claim(431, "e1"))

        XCTAssertTrue(CommandSequenceGate(store: store).accepts(claim(1, "e2")))
    }

    /// Two resource types are two independent counters relay-side (ADR
    /// 0015 / ADR 0018), so they must be two independent marks here.
    /// Only `audio` exists today; a shared mark would break the day
    /// `hid` arrives, in a way that looks like dropped commands.
    func testResourcesKeepIndependentMarks() {
        let store = InMemorySequenceStore()
        let audio = CommandSequenceGate(store: store, resource: "audio")
        let hid = CommandSequenceGate(store: store, resource: "hid")
        audio.record(claim(40, "e1"))

        XCTAssertTrue(hid.accepts(claim(1, "e1")))
        XCTAssertFalse(audio.accepts(claim(1, "e1")))
    }
}

/// Acceptance criterion 3, against the real `UserDefaults` backing.
///
/// Each test gets its own suite-named `UserDefaults`, removed
/// afterwards, so nothing here can touch the developer's own `defaults`
/// - the same discipline `AdapterProvisioning`'s `defaults` parameter
/// exists to allow.
final class UserDefaultsSequenceStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "app.thrw.mac.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAStoreThatHasNeverBeenWrittenReadsBackNothing() {
        XCTAssertNil(UserDefaultsSequenceStore(defaults: defaults).load(resource: resourceAudio))
    }

    func testASavedMarkRoundTrips() {
        UserDefaultsSequenceStore(defaults: defaults)
            .save(resource: resourceAudio, mark: SequenceMark(epoch: "e1", seq: 42))

        XCTAssertEqual(
            SequenceMark(epoch: "e1", seq: 42),
            UserDefaultsSequenceStore(defaults: defaults).load(resource: resourceAudio)
        )
    }

    /// A second store over the same defaults is what a relaunch looks
    /// like.
    func testTheMarkSurvivesTheStoreBeingRebuilt() {
        UserDefaultsSequenceStore(defaults: defaults)
            .save(resource: resourceAudio, mark: SequenceMark(epoch: "e1", seq: 3))

        let gate = CommandSequenceGate(store: UserDefaultsSequenceStore(defaults: defaults))

        XCTAssertFalse(gate.accepts(CommandPayload(type: .claim, seq: 3, epoch: "e1")))
        XCTAssertTrue(gate.accepts(CommandPayload(type: .claim, seq: 4, epoch: "e1")))
    }

    func testResourcesAreStoredUnderSeparateKeys() {
        let store = UserDefaultsSequenceStore(defaults: defaults)

        store.save(resource: "audio", mark: SequenceMark(epoch: "e1", seq: 10))
        store.save(resource: "hid", mark: SequenceMark(epoch: "e1", seq: 2))

        XCTAssertEqual(SequenceMark(epoch: "e1", seq: 10), store.load(resource: "audio"))
        XCTAssertEqual(SequenceMark(epoch: "e1", seq: 2), store.load(resource: "hid"))
    }

    /// `seq 0` is a legitimate stored value and must not read back as
    /// "nothing stored" - which is why this reads through
    /// `object(forKey:)` rather than `integer(forKey:)`, whose missing
    /// value is also 0. The relay's first command in an epoch is seq 1,
    /// so this is defensive today; it stops being defensive the moment
    /// anything ever stamps a zero.
    func testAStoredZeroIsAMarkNotAnAbsence() {
        let store = UserDefaultsSequenceStore(defaults: defaults)

        store.save(resource: resourceAudio, mark: SequenceMark(epoch: "e1", seq: 0))

        XCTAssertEqual(SequenceMark(epoch: "e1", seq: 0), store.load(resource: resourceAudio))
    }
}
