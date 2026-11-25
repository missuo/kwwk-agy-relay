// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "kwwk-agy-relay",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "kwwk-agy-relay", targets: ["kwwk-agy-relay"]),
        .library(name: "AgyRelayCore", targets: ["AgyRelayCore"]),
    ],
    dependencies: [
        // HTTP/1.1 server for the Anthropic Messages endpoint and the
        // loopback MCP server agy reaches client tools on.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // SHA-256 for transcript digests on Linux (CryptoKit is Apple-only).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AgyRelayCore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "kwwk-agy-relay",
            dependencies: [
                "AgyRelayCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AgyRelayCoreTests",
            dependencies: ["AgyRelayCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
