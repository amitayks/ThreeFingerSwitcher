// swift-tools-version: 6.2
import PackageDescription

// The shared, cross-platform device-link packages: the wire contract, the iOS "moved items" store, and
// the pairing crypto. ZERO external dependencies (no MLX/AppKit/UIKit), declared for BOTH macOS and iOS
// so the macOS app and the iOS companion app can each consume the products. Verified under `swift test`.
let package = Package(
    name: "DeviceLinkKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v15)
    ],
    products: [
        .library(name: "DeviceLinkProtocol", targets: ["DeviceLinkProtocol"]),
        .library(name: "DeviceLinkMirror", targets: ["DeviceLinkMirror"]),
        .library(name: "DeviceLinkPairing", targets: ["DeviceLinkPairing"])
    ],
    targets: [
        .target(
            name: "DeviceLinkProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeviceLinkMirror",
            dependencies: ["DeviceLinkProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeviceLinkPairing",
            dependencies: ["DeviceLinkProtocol"],   // for DeviceIdentity (QR payload + pairing exchange)
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeviceLinkProtocolTests",
            dependencies: ["DeviceLinkProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DeviceLinkMirrorTests",
            dependencies: ["DeviceLinkMirror"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DeviceLinkPairingTests",
            dependencies: ["DeviceLinkPairing", "DeviceLinkProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
