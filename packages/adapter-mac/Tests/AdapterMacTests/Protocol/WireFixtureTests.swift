import XCTest

@testable import AdapterMac

/// Asserts this adapter's **payload** types against the shared fixture at
/// `packages/protocol/fixtures/topics.json`'s sibling,
/// `packages/protocol/fixtures/wire.json` (#317).
///
/// `TopicsFixtureTests` next door does this for topic strings (#171) and
/// stops there. The message bodies are hand-written three times —
/// TypeScript across `packages/protocol` and `packages/relay-core`, Kotlin
/// in `adapter-android`'s `Payloads.kt`, and this adapter's
/// `Payloads.swift` — and `Payloads.swift`'s own header says nothing
/// catches them drifting. This is that something.
///
/// ## What is asserted, and in which direction
///
/// The fixture's `directions` section splits messages by who sends them,
/// and the two get different treatment on purpose:
///
/// - **`nodeToRelay`** — this adapter *sends* these, so it must encode to
///   exactly the fixture object. The stronger assertion.
/// - **`relayToNode`** — this adapter only *receives* these, so it must
///   decode them without loss. Holding it to an encode it never performs
///   would fail falsely: `stateNoHolder` is `{"holder": null}`, and
///   Swift's synthesised encoder omits a nil `Optional`, so re-encoding
///   would produce `{}`. Nothing is wrong there — adapters never publish
///   state.
///
/// ## What is deliberately *not* asserted
///
/// The **priority ranking** of `EventKind`. The fixture lists the kinds in
/// priority order because the relay needs that order, but
/// `EventKind`'s own doc comment is explicit that adapters must not mirror
/// it — architecture.md requires priority rules to live server-side,
/// "never duplicated in adapters". So this asserts the *set* of wire
/// spellings and says nothing about their order. Asserting the order here
/// would be a test enforcing the opposite of the architecture.
final class WireFixtureTests: XCTestCase {

    // MARK: - Loading

    /// Walked up from this file rather than bundled as a SwiftPM
    /// resource, for the same reason `TopicsFixtureTests` does it: a
    /// declared-and-copied resource is a second source of truth, which is
    /// the thing this test exists to prevent.
    private static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Protocol
            .deletingLastPathComponent()  // AdapterMacTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // adapter-mac
            .deletingLastPathComponent()  // packages
            .appendingPathComponent("protocol/fixtures/wire.json")
    }

    private func fixtureRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL())
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("shared wire fixture is not a JSON object")
        }
        return root
    }

    private func section(_ name: String) throws -> [String: Any] {
        guard let value = try fixtureRoot()[name] as? [String: Any] else {
            XCTFail("shared wire fixture has no `\(name)` section")
            return [:]
        }
        return value
    }

    private func strings(_ section: String, _ key: String) throws -> [String] {
        guard let value = try self.section(section)[key] as? [String] else {
            XCTFail("`\(section).\(key)` is not an array of strings")
            return []
        }
        return value
    }

    /// One canonical wire object, with the reader-facing `$comment`
    /// stripped — it is documentation, never a wire field.
    private func message(_ name: String) throws -> [String: Any] {
        guard var object = try section("messages")[name] as? [String: Any] else {
            XCTFail("shared wire fixture has no message named `\(name)`")
            return [:]
        }
        object.removeValue(forKey: "$comment")
        return object
    }

    private func messageData(_ name: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: try message(name))
    }

    // MARK: - Round-trip helpers

    /// Encodes `value` and compares it to the fixture object as **parsed
    /// JSON**, not as text: key order is not part of the wire contract and
    /// comparing serialised strings would make this test fail on a
    /// reordering that changes nothing.
    private func assertEncodes<T: Encodable>(
        _ value: T,
        toMessage name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
        guard let encodedObject = encoded as? [String: Any] else {
            return XCTFail("encoding \(T.self) did not produce a JSON object", file: file, line: line)
        }
        XCTAssertEqual(
            encodedObject as NSDictionary,
            try message(name) as NSDictionary,
            "\(T.self) does not encode to the shared fixture's `\(name)`",
            file: file,
            line: line
        )
    }

    // MARK: - Shared constants

    /// The one number #206 criterion 2 is explicit about: an adapter that
    /// picked its own bound would make the aggregate switch success rate
    /// meaningless, because an outcome would not mean the same thing in
    /// every row. Three hand-written declarations, now one assertion.
    func testCommandOutcomeTimeoutMatchesTheSharedFixture() throws {
        let expected = try section("constants")["commandOutcomeTimeoutMs"] as? Int
        XCTAssertEqual(commandOutcomeTimeout, .milliseconds(expected ?? -1))
    }

    /// `HeartbeatPublisher.swift` carries the same "must stay equal"
    /// warning as `CommandTimeout.swift`, about this number.
    func testHeartbeatIntervalMatchesTheSharedFixture() throws {
        let expected = try section("constants")["heartbeatIntervalMs"] as? Int
        XCTAssertEqual(defaultHeartbeatInterval, .milliseconds(expected ?? -1))
    }

    // MARK: - Closed vocabularies

    /// Both directions, which is what `CaseIterable` buys: every wire
    /// spelling in the fixture must decode into a case, **and** every case
    /// must appear in the fixture. Without the second half an adapter
    /// could grow a kind the relay has never heard of and no test would
    /// notice.
    ///
    /// Set comparison, deliberately — see the class doc on why the order
    /// of `eventKinds` must not be asserted here.
    func testEventKindsMatchTheSharedFixtureAsASet() throws {
        let declared = Set(try strings("vocabularies", "eventKinds"))
        XCTAssertEqual(Set(EventKind.allCases.map(\.rawValue)), declared)
        for spelling in declared {
            XCTAssertNotNil(EventKind(rawValue: spelling), "no EventKind for `\(spelling)`")
        }
    }

    func testCommandTypesMatchTheSharedFixture() throws {
        XCTAssertEqual(
            Set(CommandType.allCases.map(\.rawValue)),
            Set(try strings("vocabularies", "commandTypes"))
        )
    }

    func testResourceTypesMatchTheSharedFixture() throws {
        XCTAssertEqual(
            Set(ResourceType.allCases.map(\.rawValue)),
            Set(try strings("vocabularies", "resourceTypes"))
        )
        XCTAssertEqual(resourceAudio, ResourceType.audio.rawValue)
    }

    func testPlatformsMatchTheSharedFixture() throws {
        XCTAssertEqual(
            Set(Platform.allCases.map(\.rawValue)),
            Set(try strings("vocabularies", "platforms"))
        )
    }

    /// Wire spelling, not identifier spelling. Swift's case is `timedOut`
    /// and it must serialise as `timed_out`; a mirror that shipped the
    /// identifier would be rejected silently by everything downstream.
    func testOutcomesAndReasonsMatchTheSharedFixture() throws {
        XCTAssertEqual(
            Set(CommandOutcome.allCases.map(\.rawValue)),
            Set(try strings("vocabularies", "outcomes"))
        )
        XCTAssertEqual(CommandOutcome.timedOut.rawValue, "timed_out")

        XCTAssertEqual(
            Set(CommandFailureReason.allCases.map(\.rawValue)),
            Set(try strings("vocabularies", "failureReasons"))
        )
    }

    func testKindDiscriminatorsMatchTheSharedFixture() throws {
        let kinds = try section("kinds")
        XCTAssertEqual(registrationKind, kinds["register"] as? String)
        XCTAssertEqual(eventEndKind, kinds["eventEnd"] as? String)
        XCTAssertEqual(commandOutcomeKind, kinds["commandOutcome"] as? String)
    }

    // MARK: - node -> relay: this adapter must encode these exactly

    func testEventEncodesToTheSharedFixture() throws {
        let raw = try message("event")
        try assertEncodes(
            EventPayload(
                type: XCTUnwrap(EventKind(rawValue: XCTUnwrap(raw["type"] as? String))),
                priority: XCTUnwrap(raw["priority"] as? Priority)
            ),
            toMessage: "event"
        )
    }

    /// An ordinary event carries **no** `kind`. That absence is what makes
    /// the discriminator on the other shapes backward-compatible: adding a
    /// kind cannot change how an existing event parses
    /// (docs/handoffs/67.md).
    func testEventCarriesNoKindDiscriminator() throws {
        XCTAssertNil(try message("event")["kind"])
    }

    /// No `priority`: ending a trigger needs only its kind, which is all
    /// `PriorityEngine.endEvent` takes.
    func testEventEndEncodesToTheSharedFixture() throws {
        let raw = try message("eventEnd")
        try assertEncodes(
            EventEndPayload(type: XCTUnwrap(EventKind(rawValue: XCTUnwrap(raw["type"] as? String)))),
            toMessage: "eventEnd"
        )
        XCTAssertNil(raw["priority"])
    }

    func testRegistrationEncodesToTheSharedFixture() throws {
        try assertRegistrationEncodes(named: "registration")
    }

    /// The absent-route and empty-`activeEvents` case. `observedRoutes`
    /// absence means *cannot determine* and leaves the relay's record
    /// alone; `false` positively asserts this node does not hold the
    /// resource. Collapsing the two hands the relay a fabricated
    /// disagreement (#191), and a node reporting `{}` repeatedly is #303's
    /// signature — which the relay has to be able to tell from a denial.
    func testRegistrationWithNoKnownRouteEncodesToTheSharedFixture() throws {
        try assertRegistrationEncodes(named: "registrationNoRouteKnown")
        let raw = try message("registrationNoRouteKnown")
        XCTAssertEqual(raw["observedRoutes"] as? [String: Bool], [:])
        XCTAssertEqual(raw["activeEvents"] as? [String], [])
    }

    private func assertRegistrationEncodes(named name: String) throws {
        let raw = try message(name)
        let manifestJSON = try XCTUnwrap(raw["manifest"] as? [String: Any])

        let manifest = NodeManifest(
            nodeId: try XCTUnwrap(manifestJSON["nodeId"] as? String),
            platform: try XCTUnwrap(Platform(rawValue: try XCTUnwrap(manifestJSON["platform"] as? String))),
            displayName: try XCTUnwrap(manifestJSON["displayName"] as? String),
            adapterVersion: try XCTUnwrap(manifestJSON["adapterVersion"] as? String),
            supportedEventKinds: try XCTUnwrap(manifestJSON["supportedEventKinds"] as? [String])
                .map { try XCTUnwrap(EventKind(rawValue: $0)) },
            supportedResourceTypes: try XCTUnwrap(manifestJSON["supportedResourceTypes"] as? [String])
                .map { try XCTUnwrap(ResourceType(rawValue: $0)) }
        )

        try assertEncodes(
            RegistrationPayload(
                manifest: manifest,
                activeEvents: try XCTUnwrap(raw["activeEvents"] as? [String])
                    .map { try XCTUnwrap(EventKind(rawValue: $0)) },
                observedRoutes: try XCTUnwrap(raw["observedRoutes"] as? [String: Bool])
            ),
            toMessage: name
        )
    }

    func testCommandOutcomesEncodeToTheSharedFixture() throws {
        for name in [
            "commandOutcomeSucceeded",
            "commandOutcomeFailed",
            "commandOutcomeSuperseded",
            "commandOutcomeTimedOut",
            "commandOutcomeUnsequenced",
        ] {
            let raw = try message(name)
            let outcome = try XCTUnwrap(
                CommandOutcome(rawValue: try XCTUnwrap(raw["outcome"] as? String)),
                "\(name): unknown outcome"
            )
            let reason = try (raw["reason"] as? String).map {
                try XCTUnwrap(CommandFailureReason(rawValue: $0), "\(name): unknown reason")
            }

            try assertEncodes(
                CommandOutcomePayload(
                    epoch: raw["epoch"] as? String,
                    seq: raw["seq"] as? Int,
                    resourceType: try XCTUnwrap(raw["resourceType"] as? String),
                    outcome: outcome,
                    reason: reason,
                    durationMs: try XCTUnwrap(raw["durationMs"] as? Int)
                ),
                toMessage: name
            )
        }
    }

    /// ADR 0019's bound, as a number rather than as prose: the fixture's
    /// `timed_out` message must carry exactly the shared timeout, or the
    /// two halves of the contract have drifted from each other.
    func testTimedOutOutcomeCarriesTheSharedBound() throws {
        let raw = try message("commandOutcomeTimedOut")
        let expected = try section("constants")["commandOutcomeTimeoutMs"] as? Int
        XCTAssertEqual(raw["durationMs"] as? Int, expected)
        XCTAssertEqual(raw["outcome"] as? String, CommandOutcome.timedOut.rawValue)
        XCTAssertNil(raw["reason"], "timed_out is its own outcome, not a failure with a reason")
    }

    /// An outcome for a command that carried neither `epoch` nor `seq`
    /// must still be publishable, or acting on such a command becomes an
    /// unmeasurable switch — the exact gap ADR 0019 exists to close.
    func testUnsequencedOutcomeOmitsEpochAndSeq() throws {
        let raw = try message("commandOutcomeUnsequenced")
        XCTAssertNil(raw["epoch"])
        XCTAssertNil(raw["seq"])
    }

    // MARK: - relay -> node: this adapter must decode these without loss

    func testCommandDecodesFromTheSharedFixture() throws {
        let decoded = try JSONDecoder().decode(CommandPayload.self, from: try messageData("command"))
        let raw = try message("command")
        XCTAssertEqual(decoded.type.rawValue, raw["type"] as? String)
        XCTAssertEqual(decoded.seq, raw["seq"] as? Int)
        XCTAssertEqual(decoded.epoch, raw["epoch"] as? String)
    }

    /// A command carrying neither `epoch` nor `seq` must still decode and
    /// be acted on. Not defensive padding: the relay half of #210 shipped
    /// before the adapter half, so builds exist that ran against a relay
    /// stamping nothing, and `CommandSequenceGate` treats an unsequenced
    /// command as acceptable rather than stale.
    func testUnsequencedCommandDecodesFromTheSharedFixture() throws {
        let decoded = try JSONDecoder().decode(
            CommandPayload.self,
            from: try messageData("commandUnsequenced")
        )
        XCTAssertEqual(decoded.type.rawValue, try message("commandUnsequenced")["type"] as? String)
        XCTAssertNil(decoded.seq)
        XCTAssertNil(decoded.epoch)
    }

    func testStateDecodesFromTheSharedFixture() throws {
        let decoded = try JSONDecoder().decode(StatePayload.self, from: try messageData("state"))
        XCTAssertEqual(decoded.holder, try message("state")["holder"] as? String)
    }

    /// `{"holder": null}` is a real answer the relay genuinely publishes
    /// when nobody holds the resource, and it must decode to a nil holder
    /// rather than throwing. `HolderState` is what keeps that distinct
    /// from "we have not heard from the relay at all" — conflating the two
    /// makes the menu assert confidently that nobody holds the headset
    /// when the truth is that it has no idea.
    func testExplicitNullHolderDecodesFromTheSharedFixture() throws {
        let raw = try message("stateNoHolder")
        XCTAssertTrue(raw.keys.contains("holder"), "the fixture must carry an explicit null")
        XCTAssertTrue(raw["holder"] is NSNull)

        let decoded = try JSONDecoder().decode(
            StatePayload.self,
            from: try messageData("stateNoHolder")
        )
        XCTAssertNil(decoded.holder)
    }

    /// The fixture's `directions` section is what decides whether a
    /// message is asserted by encoding or by decoding, so a message added
    /// without a direction would silently be covered by neither. This
    /// asserts the section is complete from this adapter's side.
    func testEveryFixtureMessageIsDirected() throws {
        let directions = try section("directions")
        let directed = Set(
            (directions["nodeToRelay"] as? [String] ?? [])
                + (directions["relayToNode"] as? [String] ?? [])
        )
        let defined = Set(try section("messages").keys).subtracting(["$comment"])
        XCTAssertEqual(directed, defined)
    }
}
