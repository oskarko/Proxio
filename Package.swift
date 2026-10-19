// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proxio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxioCore", targets: ["ProxioCore"]),
        .library(name: "ProxioProxy", targets: ["ProxioProxy"]),
        .library(name: "ProxioSystem", targets: ["ProxioSystem"]),
        .executable(name: "ProxioApp", targets: ["ProxioApp"]),
        .executable(name: "proxio-cli", targets: ["proxio-cli"]),
        .executable(name: "ProxioHelper", targets: ["ProxioHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
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
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "ProxioSystem"),
        .executableTarget(
            name: "ProxioApp",
            dependencies: ["ProxioCore", "ProxioProxy", "ProxioSystem"],
            exclude: ["Localization"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ProxioHelper",
            dependencies: ["ProxioSystem"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "proxio-cli",
            dependencies: ["ProxioCore", "ProxioProxy", "ProxioSystem"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ProxioSystemTests", dependencies: ["ProxioSystem"]),
        .testTarget(name: "ProxioCoreTests", dependencies: ["ProxioCore"]),
        .testTarget(
            name: "ProxioProxyTests",
            dependencies: [
                "ProxioProxy",
                "ProxioCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
