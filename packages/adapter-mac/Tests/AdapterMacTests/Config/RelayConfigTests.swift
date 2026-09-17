import XCTest

@testable import AdapterMac

/// Mirrors `adapter-android`'s `RelayConfigTest.kt` test-for-test, with
/// one deliberate difference: `webSocketPath` here keeps its leading `/`
/// (MQTTNIO's convention), where the Kotlin tests assert the stripped
/// form (HiveMQ's convention) - see `RelayConfig.webSocketPath`'s own
/// doc comment for why.
final class RelayConfigTests: XCTestCase {
    func testWssUrlResolvesToWebSocketPlusTlsPerADR0001() throws {
        let config = try RelayConfig.from(url: "wss://relay.example.com:8884/mqtt")

        XCTAssertEqual(config.host, "relay.example.com")
        XCTAssertEqual(config.port, 8884)
        XCTAssertTrue(config.tls)
        XCTAssertTrue(config.webSocket)
        XCTAssertEqual(config.webSocketPath, "/mqtt")
    }

    func testWssUrlWithoutAnExplicitPortDefaultsTo443() throws {
        let config = try RelayConfig.from(url: "wss://relay.example.com/mqtt")
        XCTAssertEqual(config.port, 443)
    }

    func testWsUrlIsWebSocketWithoutTlsForALocalOrSelfHostedBroker() throws {
        let config = try RelayConfig.from(url: "ws://localhost:8080/mqtt")

        XCTAssertFalse(config.tls)
        XCTAssertTrue(config.webSocket)

        let noPortConfig = try RelayConfig.from(url: "ws://localhost/mqtt")
        XCTAssertEqual(noPortConfig.port, 80)
    }

    func testPlainMqttSchemesResolveToTheirConventionalPorts() throws {
        XCTAssertEqual(try RelayConfig.from(url: "mqtt://localhost").port, 1883)
        XCTAssertEqual(try RelayConfig.from(url: "mqtts://relay.example.com").port, 8883)
        XCTAssertFalse(try RelayConfig.from(url: "mqtt://localhost").webSocket)
    }

    func testAWebSocketUrlWithNoPathFallsBackToTheConventionalMqttPath() throws {
        let config = try RelayConfig.from(url: "wss://relay.example.com:8884")
        XCTAssertEqual(config.webSocketPath, "/mqtt")
    }

    func testAnUnsupportedSchemeIsRejectedRatherThanSilentlyDowngraded() {
        XCTAssertThrowsError(try RelayConfig.from(url: "https://relay.example.com")) { error in
            guard case RelayConfig.ParseError.unsupportedScheme = error else {
                XCTFail("expected .unsupportedScheme, got \(error)")
                return
            }
        }
    }

    func testAUrlWithNoHostIsRejected() {
        XCTAssertThrowsError(try RelayConfig.from(url: "wss:///mqtt")) { error in
            guard case RelayConfig.ParseError.missingHost = error else {
                XCTFail("expected .missingHost, got \(error)")
                return
            }
        }
    }

    /// ADR 0005: the relay endpoint must come from build-time
    /// configuration (`packages/adapter-mac/config/adapter.properties` ->
    /// the generated `AdapterBuildConfig`), never a literal in source.
    /// Asserts the generated value is actually wired through and is ADR
    /// 0001's `wss://` transport.
    func testTheBuildTimeConfiguredRelayIsReachableThroughRelayConfig() throws {
        XCTAssertTrue(AdapterBuildConfig.relayURL.hasPrefix("wss://"), AdapterBuildConfig.relayURL)
        XCTAssertFalse(AdapterBuildConfig.licensingURL.isEmpty)

        let config = try RelayConfig.fromBuildConfig()

        XCTAssertTrue(config.tls)
        XCTAssertTrue(config.webSocket)
    }
}
