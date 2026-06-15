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
        // The shared device-link packages (wire contract / mirror store / pairing crypto), extracted to a
        // standalone cross-platform package (macOS + iOS, no MLX) so the iOS companion app can consume the
        // same code. Core depends on DeviceLinkProtocol from here.
        .package(path: "../DeviceLinkKit"),
        // The MLX/Gemma 4 runtime. Pulls mlx-swift / swift-transformers / mlx-swift-lm transitively.
        // Building anything that links this needs `xcodebuild` (Metal shaders) — see GemmaRuntime target.
        // PINNED to an exact revision (not `branch: "main"`): the upstream `main` drifts and has shipped
        // commits that fail to compile (e.g. a `Float`→`MLXArray` type error in LoRA/TurboQuant). A
        // branch requirement let CI re-resolve to a broken HEAD and fail the release build even though
        // the committed Package.resolved pinned a good commit. An exact revision freezes it everywhere.
        // To bump: change the SHA here, re-resolve, and verify with `xcodebuild`.
        .package(url: "https://github.com/VincentGourbin/gemma-4-swift-mlx",
                 revision: "c6f8ab5820379898b1d437e8e5c463f376672613")
    ],
    targets: [
        // All app logic lives in this library so the test target can `@testable import` it.
        // (A test target cannot @testable-import an executable module with top-level code.)
        .target(
            name: "ThreeFingerSwitcherCore",
            dependencies: [
                .product(name: "OpenMultitouchSupport", package: "OpenMultitouchSupport"),
                // The shared wire contract — used by the device-link inbound adapter (LinkItem → ClipboardEntry).
                .product(name: "DeviceLinkProtocol", package: "DeviceLinkKit"),
                // The shared pairing crypto — used by the Mac QR pairing (PairingExchange / QR payload).
                .product(name: "DeviceLinkPairing", package: "DeviceLinkKit")
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
            dependencies: [
                "ThreeFingerSwitcherCore", "GemmaRuntime"
            ],
            path: "Sources/ThreeFingerSwitcherApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ThreeFingerSwitcherTests",
            dependencies: [
                "ThreeFingerSwitcherCore",
                // The adapter/connection/QR tests import the wire contract + pairing crypto directly.
                .product(name: "DeviceLinkProtocol", package: "DeviceLinkKit"),
                .product(name: "DeviceLinkPairing", package: "DeviceLinkKit")
            ],
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
