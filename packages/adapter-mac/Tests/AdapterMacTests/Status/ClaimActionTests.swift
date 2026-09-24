import XCTest

@testable import AdapterMac

/// #234. The precedence between "the relay says we hold it" and "the user
/// tapped Claim here" is the whole decision, so it is tested as a pure
/// function - the same treatment ``nodeStatus(isConnected:holdsRoute:)``
/// gets, and for the same reason: inside an `NSMenuItem` none of this is
/// reachable from a test.
final class ClaimActionTests: XCTestCase {
    /// The reported symptom, directly. A Mac holding the headset because
    /// Spotify is playing used to offer "Claim Headset".
    func testANodeHoldingTheHeadsetDoesNotOfferToClaimIt() {
        let action = claimAction(holdsClaim: true, manualClaimHeld: false, because: .media)

        XCTAssertNotEqual(action.title, "Claim Headset")
        XCTAssertEqual(action.title, "Holding \u{2014} playing media")
        XCTAssertFalse(action.isEnabled, "a media hold cannot be released from here - see the kdoc")
    }

    func testEachTriggerNamesItselfInTheReadout() {
        XCTAssertEqual(
            claimAction(holdsClaim: true, manualClaimHeld: false, because: .call).title,
            "Holding \u{2014} on a call"
        )
        XCTAssertEqual(
            claimAction(holdsClaim: true, manualClaimHeld: false, because: .voip).title,
            "Holding \u{2014} in a VoIP call"
        )
    }

    /// The relay can make this node holder with no local trigger active -
    /// it is the only node, say. Inventing a reason would be worse than
    /// omitting one.
    func testHoldingWithNoKnownTriggerStillReadsHonestly() {
        let action = claimAction(holdsClaim: true, manualClaimHeld: false, because: nil)

        XCTAssertEqual(action.title, "Holding headset")
        XCTAssertFalse(action.isEnabled)
    }

    func testAManualClaimOffersToReleaseIt() {
        let action = claimAction(holdsClaim: true, manualClaimHeld: true, because: .manualClaim)

        XCTAssertEqual(action.title, "Release Headset")
        XCTAssertTrue(action.isEnabled)
    }

    /// A claim published but not yet granted is still the user's to
    /// cancel, so the manual-claim branch deliberately does not consult
    /// the holder.
    func testAManualClaimTheRelayHasNotGrantedYetIsStillReleasable() {
        let action = claimAction(holdsClaim: false, manualClaimHeld: true, because: .manualClaim)

        XCTAssertEqual(action.title, "Release Headset")
        XCTAssertTrue(action.isEnabled)
    }

    func testNotHoldingOffersToClaim() {
        let action = claimAction(holdsClaim: false, manualClaimHeld: false, because: nil)

        XCTAssertEqual(action.title, "Claim Headset")
        XCTAssertTrue(action.isEnabled)
    }

    /// An unknown holder degrades to the useful control, not to a readout
    /// that might be wrong. Claiming is always safe and always meaningful.
    func testAnUnknownHolderStillOffersToClaim() {
        let action = claimAction(holdsClaim: nil, manualClaimHeld: false, because: nil)

        XCTAssertEqual(action.title, "Claim Headset")
        XCTAssertTrue(action.isEnabled)
    }

    /// #234's second symptom in miniature: before this, the label came
    /// from the manual-claim flag alone, so these two inputs produced the
    /// same answer. They must not.
    func testHoldingAndNotHoldingProduceDifferentAnswersWithoutAManualClaim() {
        let holding = claimAction(holdsClaim: true, manualClaimHeld: false, because: .media)
        let notHolding = claimAction(holdsClaim: false, manualClaimHeld: false, because: nil)

        XCTAssertNotEqual(holding, notHolding)
    }
}
