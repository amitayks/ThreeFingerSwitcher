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
        // The shared device-link packages (wire contract / mirror store / pairing crypto): a standalone
        // cross-platform package (macOS + iOS, no MLX) so the iOS companion app can consume the same code.
        // VENDORED in-repo at ./DeviceLinkKit (rather than a `../` sibling) so CI can resolve it — the
        // sibling path only existed on the maintainer's machine and broke the release build. Keep this
        // copy in sync with the standalone package if the iOS app consumes a separate copy.
        .package(path: "DeviceLinkKit")
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
        // Thin executable: calls runThreeFingerSwitcher() from Core.
        .executableTarget(
            name: "ThreeFingerSwitcher",
            dependencies: [
                "ThreeFingerSwitcherCore"
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
