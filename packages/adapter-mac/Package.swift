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
// AppKit, which doesn't exist on Linux, and `swift build`/`swift test`
// build every target in the manifest by default, not just the ones a
// test target depends on - so an unconditionally-declared AppKit target
// would break a Linux build outright, not just fail to run. Guarding the
// whole product/target declaration at the manifest level (rather than
// `#if canImport(AppKit)` inside the target's own source, the pattern
// IOBluetoothPeripheralGateway.swift uses) is the only option here: an
// executableTarget needs a real `@main` entry point on every platform it's
// compiled for, and a file that's entirely conditioned away would leave
// none. Package.swift itself is plain Swift, evaluated by whichever
// toolchain is currently resolving the manifest, so this `#if os(macOS)`
// is false on Linux and true on macOS.
//
// Note on *who* builds this on Linux: nothing in this repo currently
// does. agent-code.yml runs on ubuntu-latest but installs no Swift
// toolchain and restricts its agent to `Bash(pnpm|git|gh *)`, so it
// cannot invoke `swift` at all; ci.yml's mac-ipad job is macOS. An
// earlier version of this comment (and several others in this package)
// claimed the agent automation runs `swift test` on Linux - it does not.
// Per ADR 0004, Linux is the Rust adapter's platform, not Swift's. This
// guard is kept because it is correct and free, not because a Linux
// build is currently exercised anywhere.
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
        // - pure Swift/SwiftNIO, so it is not tied to Apple platforms.
        // That last point was originally justified by a claim that this
        // repo's agent automation builds Swift on Linux; it does not (see
        // the #if os(macOS) comment above). The first three reasons stand
        // on their own - portability is a nice-to-have here, not the
        // load-bearing argument it was written as.
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.0.0"),
    ],
    targets: targets
)
