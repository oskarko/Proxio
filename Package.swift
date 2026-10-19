// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wireway",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WirewayCore", targets: ["WirewayCore"]),
    ],
    targets: [
        .target(name: "WirewayCore"),
        .testTarget(name: "WirewayCoreTests", dependencies: ["WirewayCore"]),
    ]
)
