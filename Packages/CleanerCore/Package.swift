// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
    ],
    targets: [
        .target(name: "CleanerCore"),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
