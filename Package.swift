// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ThreeFingerSwitcher",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Product name is UNCHANGED so scripts/build-app.sh keeps working.
        .executable(name: "ThreeFingerSwitcher", targets: ["ThreeFingerSwitcher"]),
        .executable(name: "TouchSpike", targets: ["TouchSpike"])
    ],
    dependencies: [
        .package(url: "https://github.com/Kyome22/OpenMultitouchSupport.git", from: "4.0.0")
    ],
    targets: [
        // All app logic lives in this library so the test target can `@testable import` it.
        // (A test target cannot @testable-import an executable module with top-level code.)
        .target(
            name: "ThreeFingerSwitcherCore",
            dependencies: [
                .product(name: "OpenMultitouchSupport", package: "OpenMultitouchSupport")
            ],
            path: "Sources/ThreeFingerSwitcher",
            swiftSettings: [
                // Pragmatic: v5 language mode avoids strict-concurrency friction in the GUI
                // layer. The Kyome package remains Sendable-clean across the boundary.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Thin executable: just calls runThreeFingerSwitcher() from the Core library.
        .executableTarget(
            name: "ThreeFingerSwitcher",
            dependencies: ["ThreeFingerSwitcherCore"],
            path: "Sources/ThreeFingerSwitcherApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ThreeFingerSwitcherTests",
            dependencies: ["ThreeFingerSwitcherCore"],
            path: "Tests/ThreeFingerSwitcherTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Throwaway verification harness (Section 1 spikes). Not bundled in the shipped app.
        .executableTarget(
            name: "TouchSpike",
            dependencies: [
                .product(name: "OpenMultitouchSupport", package: "OpenMultitouchSupport")
            ],
            path: "Sources/TouchSpike"
        )
    ]
)
