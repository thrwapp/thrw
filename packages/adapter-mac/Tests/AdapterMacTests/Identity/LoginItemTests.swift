import XCTest

@testable import AdapterMac

/// Fakes the ``LoginItemController`` boundary - the real
/// `SMAppServiceLoginItem` mutates the user's actual Login Items and
/// needs a real `.app` bundle, so it can't run here.
private final class FakeLoginItemController: LoginItemController, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: LoginItemState
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    var registerError: Error?

    struct Boom: Error {}

    init(state: LoginItemState) { _state = state }

    func currentState() -> LoginItemState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    func register() throws {
        lock.lock(); defer { lock.unlock() }
        registerCalls += 1
        if let registerError { throw registerError }
        _state = .enabled
    }

    func unregister() throws {
        lock.lock(); defer { lock.unlock() }
        unregisterCalls += 1
        _state = .notRegistered
    }
}

final class LoginItemTests: XCTestCase {
    func testTheToggleIsOffBeforeTheUserOptsIn() {
        XCTAssertFalse(LoginItem.isOn(.notRegistered))
    }

    func testTheToggleIsOnWhenEnabled() {
        XCTAssertTrue(LoginItem.isOn(.enabled))
    }

    /// The user has already opted in; the outstanding approval is
    /// something only System Settings can resolve. Showing this unchecked
    /// would invite a second click that does nothing useful.
    func testAwaitingApprovalCountsAsOnNotOff() {
        XCTAssertTrue(LoginItem.isOn(.requiresApproval))
    }

    /// Verified against a real unsigned bundle: macOS reports `notFound`
    /// before an app has ever registered, so this is the fresh-install
    /// state, not a failure.
    func testANeverRegisteredAppReadsAsOff() {
        XCTAssertFalse(LoginItem.isOn(.notFound))
    }

    func testClickingTogglesAgainstWhateverTheSystemCurrentlyReports() {
        XCTAssertEqual(LoginItem.action(for: .notRegistered), .register)
        XCTAssertEqual(LoginItem.action(for: .notFound), .register)
        XCTAssertEqual(LoginItem.action(for: .enabled), .unregister)
        XCTAssertEqual(LoginItem.action(for: .requiresApproval), .unregister)
    }

    /// #144 acceptance criterion 3: the user can revoke a login item in
    /// System Settings without telling the app, so the next click must be
    /// decided from the live system state, never a remembered flag.
    func testRevokingOutsideTheAppIsReflectedOnTheNextRead() {
        let controller = FakeLoginItemController(state: .enabled)
        XCTAssertEqual(LoginItem.action(for: controller.currentState()), .unregister)

        // Simulates the user switching it off in System Settings.
        try? controller.unregister()

        XCTAssertEqual(LoginItem.action(for: controller.currentState()), .register)
        XCTAssertFalse(LoginItem.isOn(controller.currentState()))
    }

    func testTheOrdinaryStatesNeedNoExplanatoryText() {
        XCTAssertNil(LoginItem.explanation(for: .enabled))
        XCTAssertNil(LoginItem.explanation(for: .notRegistered))
    }

    /// Regression guard: `notFound` is the *fresh install* state (proved
    /// against a real unsigned bundle), so captioning it with anything
    /// like "move thrw to Applications" would alarm every first-time
    /// user. An earlier version of this code did exactly that.
    func testANeverRegisteredAppIsNotCaptionedWithAnError() {
        XCTAssertNil(LoginItem.explanation(for: .notFound))
    }

    /// The one state the user genuinely cannot resolve by clicking again.
    func testAwaitingSystemApprovalIsExplained() {
        XCTAssertNotNil(LoginItem.explanation(for: .requiresApproval))
    }

    func testRegisteringThroughTheControllerTurnsTheToggleOn() throws {
        let controller = FakeLoginItemController(state: .notRegistered)

        try controller.register()

        XCTAssertEqual(controller.registerCalls, 1)
        XCTAssertTrue(LoginItem.isOn(controller.currentState()))
    }

    /// A failed registration must leave the toggle reflecting reality -
    /// the state is re-read from the controller, not assumed from the
    /// attempt.
    func testAFailedRegistrationLeavesTheToggleOff() {
        let controller = FakeLoginItemController(state: .notRegistered)
        controller.registerError = FakeLoginItemController.Boom()

        XCTAssertThrowsError(try controller.register())

        XCTAssertFalse(LoginItem.isOn(controller.currentState()))
    }
}
