// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ScrubberKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ScrubberKit",
            targets: ["ScrubberKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.7"),
    ],
    targets: [
        .target(
            name: "ScrubberKit",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [
                .process("Resources/turndown-license"),
                .process("Resources/turndown-webkit-lite.js"),
                .process("Resources/turndown.js"),
            ]
        ),
        .testTarget(
            name: "ScrubberKitTests",
            dependencies: ["ScrubberKit"]
        ),
    ],

    swiftLanguageModes: [.v6]
)
