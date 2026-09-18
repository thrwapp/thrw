// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "AdapterMac", targets: ["AdapterMac"])
]

var targets: [Target] = [
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

// AdapterMacApp (#128) is the menu-bar composition root - it imports
// AppKit, which doesn't exist on Linux. This repo's agent-code/agent-eval
// automation runs `swift test` on a Linux container (only ci.yml's
// mac-ipad job uses real macOS - see MQTTNIOTransport.swift's own
// comment on the same constraint), and `swift build`/`swift test` build
// every target in the manifest by default, not just the ones a test
// target depends on - so an unconditionally-declared AppKit target would
// break that Linux build outright, not just fail to run. Guarding the
// whole product/target declaration at the manifest level (rather than
// `#if canImport(AppKit)` inside the target's own source, the pattern
// IOBluetoothPeripheralGateway.swift uses) is the only option here: an
// executableTarget needs a real `@main` entry point on every platform it's
// compiled for, and a file that's entirely conditioned away would leave
// none. Package.swift itself is plain Swift, evaluated by whichever
// toolchain is currently resolving the manifest, so this `#if os(macOS)`
// is false on the Linux runner and true on the real macOS one.
#if os(macOS)
products.append(.executable(name: "AdapterMacApp", targets: ["AdapterMacApp"]))
targets.append(
    .executableTarget(
        name: "AdapterMacApp",
        dependencies: ["AdapterMac"],
        // Info.plist is reserved by SwiftPM's resource pipeline (it would
        // collide with a resource bundle's own generated Info.plist) -
        // excluded from the source scan rather than declared as a
        // resource. Scripts/build-app-bundle.sh copies it directly by
        // path into the assembled .app bundle instead.
        exclude: ["Info.plist"]
    )
)
#endif

let package = Package(
    name: "AdapterMac",
    platforms: [
        .macOS(.v13)
    ],
    products: products,
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
    targets: targets
)
