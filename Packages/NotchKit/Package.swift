// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .library(name: "NotchUI", targets: ["NotchUI"]),
        .library(name: "MediaBridge", targets: ["MediaBridge"]),
    ],
    targets: [
        .target(name: "NotchCore"),
        .target(name: "NotchUI", dependencies: ["NotchCore"]),
        .target(name: "MediaBridge"),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchUITests", dependencies: ["NotchUI"]),
        .testTarget(name: "MediaBridgeTests", dependencies: ["MediaBridge"]),
    ]
)
