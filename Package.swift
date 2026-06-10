// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "sdkJanus",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "sdkJanus",
            targets: ["sdkJanus"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Meonardo/WebRTC.git", from: "91.0.1"),
            .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.8"),

    ],
    targets: [
        .target(
            name: "sdkJanus",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "Starscream", package: "Starscream"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
