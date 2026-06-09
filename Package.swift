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
        .package(url: "https://github.com/Kyome22/OpenMultitouchSupport.git", from: "4.0.0"),
        // The MLX/Gemma 4 runtime. Pulls mlx-swift / swift-transformers / mlx-swift-lm transitively.
        // Building anything that links this needs `xcodebuild` (Metal shaders) — see GemmaRuntime target.
        .package(url: "https://github.com/VincentGourbin/gemma-4-swift-mlx", branch: "main")
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
        // The MLX/Gemma 4 runtime, ISOLATED in its own target so `ThreeFingerSwitcherCore` and the
        // test target stay MLX-free and keep building under plain `swift build`/`swift test`. This
        // target links MLX (Metal shaders) so it — and anything depending on it (the app) — builds
        // ONLY via `xcodebuild`, never `swift build`. It conforms to Core's public `LLMRuntime` seam.
        .target(
            name: "GemmaRuntime",
            dependencies: [
                "ThreeFingerSwitcherCore",
                .product(name: "Gemma4Swift", package: "gemma-4-swift-mlx")
            ],
            path: "Sources/GemmaRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Thin executable: calls runThreeFingerSwitcher() from Core and injects the real Gemma runtime
        // (from GemmaRuntime) at the model seam. Builds via `xcodebuild` (it transitively links MLX).
        .executableTarget(
            name: "ThreeFingerSwitcher",
            dependencies: ["ThreeFingerSwitcherCore", "GemmaRuntime"],
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
        ),
        // Throwaway harness for the four-finger-launcher spikes (S-OQ1 haptics, S-OQ3 window move).
        // Not bundled in the shipped app.
        .executableTarget(
            name: "LauncherSpike",
            path: "Sources/LauncherSpike",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
