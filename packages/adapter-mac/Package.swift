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
    targets: [
        .target(name: "AdapterMac"),
        .testTarget(name: "AdapterMacTests", dependencies: ["AdapterMac"])
    ]
)
