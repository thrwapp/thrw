import XCTest

@testable import AdapterMac

final class ArbitrationPauseTests: XCTestCase {
    func testTogglingOnPauses() async throws {
        let pause = ArbitrationPause(node: RecordingEventLifecycle())

        let paused = try await pause.toggle()

        XCTAssertTrue(paused)
        XCTAssertTrue(pause.isPaused())
    }

    func testTogglingOffResumes() async throws {
        let pause = ArbitrationPause(node: RecordingEventLifecycle())

        _ = try await pause.toggle()
        let paused = try await pause.toggle()

        XCTAssertFalse(paused)
        XCTAssertFalse(pause.isPaused())
    }

    /// #290 criterion 2, and the reason suppressing future triggers is
    /// not enough on its own: the relay counts what it was last told, so
    /// a paused holder that only stopped *emitting* would keep the
    /// headset until something else outranked it — exactly the
    /// situation the user is trying to escape.
    func testPausingEndsTheTriggersThisNodeHadActive() async throws {
        let node = RecordingEventLifecycle()
        try await node.emitEvent(type: .media, priority: unrankedPriority)
        try await node.emitEvent(type: .voip, priority: unrankedPriority)
        let pause = ArbitrationPause(node: node)

        _ = try await pause.toggle()

        XCTAssertEqual(Set(node.ended), [.media, .voip])
    }

    /// Resuming must not re-assert anything. The triggers were ended on
    /// the wire; whether they are still true is for the monitors to
    /// report afresh, and inventing them here would publish a trigger
    /// for something that may have stopped while paused.
    func testResumingDoesNotReEmitAnything() async throws {
        let node = RecordingEventLifecycle()
        try await node.emitEvent(type: .media, priority: unrankedPriority)
        let pause = ArbitrationPause(node: node)
        _ = try await pause.toggle()
        let emittedBefore = node.emitted.count

        _ = try await pause.toggle()

        XCTAssertEqual(node.emitted.count, emittedBefore)
    }

    func testPausingWithNothingActiveEndsNothing() async throws {
        let node = RecordingEventLifecycle()
        let pause = ArbitrationPause(node: node)

        _ = try await pause.toggle()

        XCTAssertTrue(node.ended.isEmpty)
    }

    /// #290 criterion 3. The Mac relaunches at every login (#144), and
    /// a pause that quietly forgot itself would hand the headset back
    /// mid-call — the failure it was turned on to prevent.
    func testTheStateSurvivesANewPauseOverTheSameStore() async throws {
        let store = InMemoryArbitrationPauseStore()
        _ = try await ArbitrationPause(node: RecordingEventLifecycle(), store: store).toggle()

        let relaunched = ArbitrationPause(node: RecordingEventLifecycle(), store: store)

        XCTAssertTrue(relaunched.isPaused())
    }
}

final class UserDefaultsArbitrationPauseStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "app.thrw.mac.tests.arbitrationPause"

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

    /// Not paused is the right default for an empty store: a fresh
    /// install must switch, not sit silently doing nothing.
    func testAnEmptyStoreIsNotPaused() {
        XCTAssertFalse(UserDefaultsArbitrationPauseStore(defaults: defaults).isPaused())
    }

    func testAPauseSurvivesANewStoreOverTheSameDefaults() {
        UserDefaultsArbitrationPauseStore(defaults: defaults).setPaused(true)

        XCTAssertTrue(UserDefaultsArbitrationPauseStore(defaults: defaults).isPaused())
    }

    func testResumingIsAlsoPersisted() {
        let store = UserDefaultsArbitrationPauseStore(defaults: defaults)
        store.setPaused(true)
        store.setPaused(false)

        XCTAssertFalse(UserDefaultsArbitrationPauseStore(defaults: defaults).isPaused())
    }
}
