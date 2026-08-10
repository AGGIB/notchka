// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .library(name: "NotchUI", targets: ["NotchUI"]),
    ],
    targets: [
        .target(name: "NotchCore"),
        .target(name: "NotchUI", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
    ]
)
