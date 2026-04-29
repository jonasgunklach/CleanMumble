// swift-tools-version:5.7
import PackageDescription

// Local helper that exposes the variadic `opus_encoder_ctl` API to Swift.
// `swift-opus` only wraps `opus_encoder_create` — bitrate, complexity, FEC,
// signal type, packet-loss-percentage, etc. are all set via the variadic
// `opus_encoder_ctl(enc, REQUEST, ...)` macro family which Swift can't call
// directly. This package provides a tiny C shim and a Swift extension that
// reaches into `Opus.Encoder` to apply those controls.
let package = Package(
    name: "OpusControl",
    platforms: [.macOS(.v10_15), .iOS(.v13)],
    products: [
        .library(name: "OpusControl", targets: ["OpusControl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/alta/swift-opus", exact: "0.0.2"),
    ],
    targets: [
        .target(
            name: "COpusControl",
            dependencies: [
                .product(name: "Copus", package: "swift-opus"),
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "OpusControl",
            dependencies: [
                "COpusControl",
                .product(name: "Opus", package: "swift-opus"),
            ]
        ),
    ]
)
