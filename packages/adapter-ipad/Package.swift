// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AdapterIpad",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "AdapterIpad", targets: ["AdapterIpad"])
    ],
    targets: [
        .target(name: "AdapterIpad"),
        .testTarget(name: "AdapterIpadTests", dependencies: ["AdapterIpad"])
    ]
)
