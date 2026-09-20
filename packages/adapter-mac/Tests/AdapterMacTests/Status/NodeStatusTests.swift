import XCTest

@testable import AdapterMac

final class NodeStatusTests: XCTestCase {
    func testConnectedAndHoldingTheRoute() {
        XCTAssertEqual(nodeStatus(isConnected: true, holdsRoute: true), .holding)
    }

    func testConnectedAndNotHolding() {
        XCTAssertEqual(nodeStatus(isConnected: true, holdsRoute: false), .notHolding)
    }

    /// #191's observer returns nil when it genuinely cannot read the
    /// route. Reporting that as "not holding" would invent an answer.
    func testConnectedButTheRouteCannotBeRead() {
        XCTAssertEqual(nodeStatus(isConnected: true, holdsRoute: nil), .unknown)
    }

    /// Disconnected outranks the route entirely. While the transport is
    /// down, any holder state is a stale belief - and this is exactly the
    /// case (#182) where the adapter looked perfectly healthy while
    /// publishing nothing, so it must not display a confident answer.
    func testDisconnectedOutranksEveryRouteState() {
        for route: Bool? in [true, false, nil] {
            XCTAssertEqual(
                nodeStatus(isConnected: false, holdsRoute: route),
                .disconnected,
                "a disconnected node must not report holder state (route=\(String(describing: route)))"
            )
        }
    }

    /// The whole point is telling the silent failures apart, so no two
    /// states may read the same.
    func testEveryStateReadsDifferently() {
        let texts = [NodeStatus.disconnected, .holding, .notHolding, .unknown].map(\.displayText)
        XCTAssertEqual(Set(texts).count, texts.count)
        XCTAssertFalse(texts.contains(where: \.isEmpty))
    }
}
