// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proxio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxioCore", targets: ["ProxioCore"]),
    ],
    targets: [
        .target(name: "ProxioCore"),
        .testTarget(name: "ProxioCoreTests", dependencies: ["ProxioCore"]),
    ]
)
