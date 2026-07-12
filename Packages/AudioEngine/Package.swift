// swift-tools-version:6.2
import PackageDescription

// CleanMumble's audio engine — see /audio-engine.md for the design document.
//
// One engine, one owner, one state machine. Control plane (EngineController,
// DeviceManager, RoutePolicy) is strictly separated from the realtime data
// plane (SPSC rings, capture/decode workers, pull-model playback). Networking
// (OCB2-encrypted Mumble UDP voice) lives here too so the transport can be
// tested against the jitter buffer without an app host.
let package = Package(
    name: "AudioEngine",
    // The app is macOS 26 (Tahoe) minimum — no pre-Tahoe support paths.
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"])
    ],
    dependencies: [
        .package(url: "https://github.com/alta/swift-opus", exact: "0.0.2"),
        .package(path: "../AudioCore"),
        .package(path: "../OpusControl"),
    ],
    targets: [
        .target(
            name: "AudioEngine",
            dependencies: [
                .product(name: "Opus", package: "swift-opus"),
                .product(name: "AudioCore", package: "AudioCore"),
                .product(name: "OpusControl", package: "OpusControl"),
            ],
            path: "Sources/AudioEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioEngineTests",
            dependencies: [
                "AudioEngine",
                .product(name: "Opus", package: "swift-opus"),
                .product(name: "OpusControl", package: "OpusControl"),
            ],
            path: "Tests/AudioEngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
