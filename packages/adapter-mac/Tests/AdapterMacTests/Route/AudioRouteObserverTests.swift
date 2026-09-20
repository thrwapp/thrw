import XCTest

@testable import AdapterMac

/// The matcher is the only assumption `CoreAudioRouteObserver` makes about
/// a string format Apple does not document, which is exactly why it is a
/// pure function with tests rather than an inline comparison.
final class AudioDeviceUIDMatchingTests: XCTestCase {
    private let address = "74-15-F5-12-2A-21"

    func testMatchesRegardlessOfSeparatorAndCase() {
        for uid in [
            "74-15-F5-12-2A-21",
            "74:15:f5:12:2a:21",
            "7415F5122A21",
            "74-15-f5-12-2a-21:output",
            "AppleHDA:74-15-F5-12-2A-21-output",
        ] {
            XCTAssertTrue(
                audioDeviceUID(uid, matchesBluetoothAddress: address),
                "expected \(uid) to match \(address)"
            )
        }
    }

    func testDoesNotMatchTheBuiltInDevices() {
        for uid in ["BuiltInSpeakerDevice", "BuiltInMicrophoneDevice"] {
            XCTAssertFalse(audioDeviceUID(uid, matchesBluetoothAddress: address))
        }
    }

    /// A different headset must not match - this is the whole point when
    /// several are paired, and the reference Mac has five.
    func testDoesNotMatchADifferentHeadset() {
        XCTAssertFalse(audioDeviceUID("90-9C-4A-E3-4A-F8", matchesBluetoothAddress: address))
    }

    /// Guards the `count == 12` check. Without it a malformed or empty
    /// address normalises to a short string that is a substring of almost
    /// any UID, so every device would read as "this is the headset" - a
    /// false `true` is worse than no answer, because it tells the relay
    /// this node holds a headset it does not.
    func testAMalformedAddressNeverMatches() {
        for bad in ["", "74-15", "not-an-address", "74-15-F5-12-2A"] {
            XCTAssertFalse(
                audioDeviceUID("74-15-F5-12-2A-21", matchesBluetoothAddress: bad),
                "a malformed address (\(bad)) must not match anything"
            )
        }
    }
}
