// swift-tools-version:6.2
import PackageDescription

// RNNoise — recurrent-neural-network noise suppression (Xiph, BSD-3, see
// COPYING). Vendored classic small-model build (2021-03, pre-nnet): the modern
// model ships as a 78 MB generated C source, whereas this one is ~415 KB and
// runs in well under 0.1 ms per 10 ms frame — the right fit for a real-time
// mic path. `CRNNoise` is the vendored C library; `RNNoise` is a thin Swift
// wrapper that handles the int16-scale convention libopus/RNNoise expect.
let package = Package(
    name: "RNNoise",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "RNNoise", targets: ["RNNoise"])
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            cSettings: [
                // Silence the vendored library's own warnings; we don't modify it.
                .unsafeFlags(["-w"]),
                // RNNoise copies Opus CELT/DNN internals (pitch_search, celt_lpc,
                // opus_fft, compute_gru, …). libopus (via swift-opus) defines the
                // same names → duplicate-symbol link errors. Force-include a
                // generated header that prefixes every non-public RNNoise symbol
                // (see rnnoise_symbol_prefix.h) so the copies link independently;
                // the public rnnoise_* API is left untouched.
                .headerSearchPath("."),
                .unsafeFlags(["-include", "rnnoise_symbol_prefix.h"]),
            ]
        ),
        .target(
            name: "RNNoise",
            dependencies: ["CRNNoise"],
            path: "Sources/RNNoise",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RNNoiseTests",
            dependencies: ["RNNoise"],
            path: "Tests/RNNoiseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
