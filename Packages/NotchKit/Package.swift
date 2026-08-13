// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .library(name: "NotchUI", targets: ["NotchUI"]),
        .library(name: "MediaBridge", targets: ["MediaBridge"]),
        .library(name: "NotchStore", targets: ["NotchStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "NotchCore"),
        .target(name: "NotchUI", dependencies: ["NotchCore"]),
        .target(name: "MediaBridge"),
        .target(name: "NotchStore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchUITests", dependencies: ["NotchUI"]),
        .testTarget(name: "MediaBridgeTests", dependencies: ["MediaBridge"]),
        .testTarget(name: "NotchStoreTests", dependencies: ["NotchStore"]),
    ]
)
