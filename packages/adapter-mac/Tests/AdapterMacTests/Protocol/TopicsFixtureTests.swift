import XCTest

@testable import AdapterMac

/// Asserts this adapter's topic builder against the **shared** fixture
/// at `packages/protocol/fixtures/topics.json` (#171).
///
/// There are three hand-written implementations of the topic contract -
/// TypeScript in `packages/protocol`, Kotlin in `adapter-android`, and
/// this one. Each had its own tests and nothing asserted they agreed, so
/// they could drift apart silently and the only symptom would be a node
/// going quiet on real hardware. That is precisely the failure mode
/// behind #174, #175 and #182, and the risk peaks during the ADR 0015
/// migration because all three move at once.
final class TopicsFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        let account: String
        let node: String
        let resourceType: ResourceType
        let topics: [String: String]
        let hid: [String: String]
    }

    private func loadFixture() throws -> Fixture {
        // Walked up from this file rather than bundled: SwiftPM resources
        // would mean declaring the JSON in Package.swift and copying it,
        // which is a second source of truth - the thing this test exists
        // to prevent.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Protocol
            .deletingLastPathComponent()  // AdapterMacTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // adapter-mac
            .deletingLastPathComponent()  // packages
            .appendingPathComponent("protocol/fixtures/topics.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testEventsTopicMatchesTheSharedFixture() throws {
        let f = try loadFixture()
        XCTAssertEqual(
            Topics.events(account: f.account, node: f.node, resource: f.resourceType),
            f.topics["events"]
        )
    }

    func testCommandsTopicMatchesTheSharedFixture() throws {
        let f = try loadFixture()
        XCTAssertEqual(
            Topics.commands(account: f.account, node: f.node, resource: f.resourceType),
            f.topics["commands"]
        )
    }

    func testStateTopicMatchesTheSharedFixture() throws {
        let f = try loadFixture()
        XCTAssertEqual(Topics.state(account: f.account, resource: f.resourceType), f.topics["state"])
    }

    /// No resource segment - ADR 0015 lists exactly three topics that
    /// gain one, and liveness is per-node.
    func testHeartbeatTopicHasNoResourceSegment() throws {
        let f = try loadFixture()
        let topic = Topics.heartbeat(account: f.account, node: f.node)
        XCTAssertEqual(topic, f.topics["heartbeat"])
        XCTAssertFalse(topic.contains(f.resourceType.rawValue))
    }

    func testHidTopicsMatchTheSharedFixture() throws {
        let f = try loadFixture()
        XCTAssertEqual(Topics.events(account: f.account, node: f.node, resource: .hid), f.hid["events"])
        XCTAssertEqual(Topics.commands(account: f.account, node: f.node, resource: .hid), f.hid["commands"])
        XCTAssertEqual(Topics.state(account: f.account, resource: .hid), f.hid["state"])
    }
}
