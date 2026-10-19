// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proxio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxioCore", targets: ["ProxioCore"]),
        .library(name: "ProxioProxy", targets: ["ProxioProxy"]),
        .executable(name: "proxio-cli", targets: ["proxio-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
    ],
    targets: [
        .target(name: "ProxioCore"),
        .target(
            name: "ProxioProxy",
            dependencies: [
                "ProxioCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "proxio-cli",
            dependencies: ["ProxioCore", "ProxioProxy"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ProxioCoreTests", dependencies: ["ProxioCore"]),
        .testTarget(
            name: "ProxioProxyTests",
            dependencies: [
                "ProxioProxy",
                "ProxioCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
