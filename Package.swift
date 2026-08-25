// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotMicPlayer",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HotMicPlayer", targets: ["HotMicPlayer"])
    ],
    targets: [
        .target(
            name: "HotMicPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HotMicPlayerTests",
            dependencies: ["HotMicPlayer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
