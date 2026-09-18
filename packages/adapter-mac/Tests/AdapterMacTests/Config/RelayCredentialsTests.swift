import XCTest

@testable import AdapterMac

/// Mirrors `adapter-android`'s `RelayCredentialsTest.kt` case-for-case -
/// the same "empty means anonymous, half-set means anonymous" rule has to
/// hold on both platforms, or one adapter silently half-authenticates
/// where the other doesn't.
final class RelayCredentialsTests: XCTestCase {
    func testACompleteCredentialIsUsed() {
        XCTAssertEqual(
            RelayCredentials.make(username: "admin", password: "hunter2"),
            RelayCredentials(username: "admin", password: "hunter2")
        )
    }

    /// The committed `adapter.properties` ships both keys empty, so this
    /// is the default state of any build without an untracked overlay -
    /// meaning "connect anonymously", not "misconfigured".
    func testBothBlankMeansAnonymous() {
        XCTAssertNil(RelayCredentials.make(username: "", password: ""))
    }

    /// Half-set is a misconfiguration that would otherwise produce a
    /// confusing broker-side rejection, so it's treated as no credentials
    /// rather than sent half-complete.
    func testAUsernameWithNoPasswordIsTreatedAsNoCredentials() {
        XCTAssertNil(RelayCredentials.make(username: "admin", password: ""))
    }

    func testAPasswordWithNoUsernameIsTreatedAsNoCredentials() {
        XCTAssertNil(RelayCredentials.make(username: "", password: "hunter2"))
    }

    /// A properties file trivially picks up trailing whitespace.
    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            RelayCredentials.make(username: "  admin\n", password: "\thunter2 "),
            RelayCredentials(username: "admin", password: "hunter2")
        )
    }

    func testWhitespaceOnlyValuesCountAsBlank() {
        XCTAssertNil(RelayCredentials.make(username: "   ", password: "   "))
    }

    /// Passwords are arbitrary text and the generator escapes them into a
    /// Swift string literal; nothing downstream should mangle them.
    func testAPasswordContainingQuotesAndBackslashesSurvivesIntact() {
        let awkward = #"p"a\ss"#
        XCTAssertEqual(RelayCredentials.make(username: "admin", password: awkward)?.password, awkward)
    }
}
