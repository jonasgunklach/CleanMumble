// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"])
    ],
    dependencies: [
        // Test-only: end-to-end Mumble audio pipeline tests need a real
        // Opus codec to verify capture → encode → transport → decode → playback
        // round-trip quality. Production AudioCore stays codec-agnostic.
        .package(url: "https://github.com/alta/swift-opus", exact: "0.0.2"),
        // Test-only: pull in the same Opus encoder-control shim the app uses
        // so test settings (bitrate / FEC / complexity / signal type) match
        // production exactly.
        .package(path: "../OpusControl"),
    ],
    targets: [
        .target(
            name: "AudioCore",
            path: "Sources/AudioCore"
        ),
        .testTarget(
            name: "AudioCoreTests",
            dependencies: [
                "AudioCore",
                .product(name: "Opus", package: "swift-opus"),
                .product(name: "OpusControl", package: "OpusControl"),
            ],
            path: "Tests/AudioCoreTests"
        )
    ]
)
