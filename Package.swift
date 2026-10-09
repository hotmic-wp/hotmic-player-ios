// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotMicPlayer",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        // Playback, playlist, plug-in protocols and the headless engagement data layer.
        .library(name: "HotMicPlayer", targets: ["HotMicPlayer"]),
        // Optional SwiftUI engagement components and ready-made layouts. Partners who
        // build their own UI on `HMEngagement` never link this.
        .library(name: "HotMicPlayerUI", targets: ["HotMicPlayerUI"])
    ],
    targets: [
        .target(
            name: "HotMicPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "HotMicPlayerUI",
            dependencies: ["HotMicPlayer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HotMicPlayerTests",
            dependencies: ["HotMicPlayer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
