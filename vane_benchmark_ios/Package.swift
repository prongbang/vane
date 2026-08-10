// swift-tools-version:5.9
// Repo-internal benchmark harness. Exists as a SEPARATE package so Alamofire
// never touches VaneSwift/Package.swift — the manifest every consumer
// resolves — mirroring how vane_benchmark/ stays out of the shipping Dart
// packages.

import PackageDescription

let package = Package(
    name: "vane_benchmark_ios",
    platforms: [
        // data(for:delegate:) needs iOS 15/macOS 12; NSLock.withLock 16/13.
        .iOS(.v16),
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "../VaneSwift"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        // Anchor target so xcodebuild generates a scheme; the harness lives
        // in the test target.
        .target(name: "VaneBenchmarkIOS"),
        .testTarget(
            name: "VaneBenchmarkIOSTests",
            dependencies: [
                "VaneBenchmarkIOS",
                .product(name: "VaneSwift", package: "VaneSwift"),
                .product(name: "Alamofire", package: "Alamofire"),
            ]
        ),
    ]
)
