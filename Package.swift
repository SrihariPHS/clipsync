// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClipSync", targets: ["ClipSync"]),
        .library(name: "ClipSyncCore", targets: ["ClipSyncCore"]),
    ],
    targets: [
        .target(name: "ClipSyncCore"),
        .executableTarget(name: "ClipSync", dependencies: ["ClipSyncCore"]),
        .testTarget(name: "ClipSyncCoreTests", dependencies: ["ClipSyncCore"]),
    ]
)
