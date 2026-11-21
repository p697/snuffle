// swift-tools-version: 6.0
import PackageDescription

// Everything the app and its widgets share: models, the four platform clients, demo data and storage.
// It builds for macOS too, so `swift test` runs the logic tests without a simulator.
let package = Package(
    name: "SnuffleKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SnuffleKit", targets: ["SnuffleKit"])
    ],
    targets: [
        .target(name: "SnuffleKit"),
        .testTarget(
            name: "SnuffleKitTests",
            dependencies: ["SnuffleKit"]
        )
    ]
)
