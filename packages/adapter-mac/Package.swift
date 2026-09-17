// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AdapterMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AdapterMac", targets: ["AdapterMac"])
    ],
    dependencies: [
        // MQTT client (ADR 0001). See Sources/AdapterMac/Mqtt/MQTTNIOTransport.swift's
        // kdoc for why MQTTNIO over CocoaMQTT: native async/await (matches
        // this package's actor-based style and AGENTS.md's Swift 6
        // concurrency convention), first-class WebSocket + TLS transport,
        // MQTT 3.1.1 support (matching relay-core's `mqtt` npm client's
        // default protocol version), and - unlike IOBluetooth/CoreBluetooth
        // - pure Swift/SwiftNIO, so it compiles and runs on the Linux
        // runner this repo's agent-code/agent-eval automation uses, not
        // only on the macOS runner `ci.yml`'s `mac-ipad` job provides.
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AdapterMac",
            dependencies: [
                .product(name: "MQTTNIO", package: "mqtt-nio"),
            ],
            plugins: [
                .plugin(name: "GenerateAdapterConfigPlugin")
            ]
        ),
        .plugin(
            name: "GenerateAdapterConfigPlugin",
            capability: .buildTool()
        ),
        .testTarget(name: "AdapterMacTests", dependencies: ["AdapterMac"]),
    ]
)
