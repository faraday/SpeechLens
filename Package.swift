// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SpeechLens",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "speechlens-cli", targets: ["CLI"]),
        .executable(name: "WeightPort", targets: ["WeightPort"]),
        .library(name: "Inference", targets: ["Inference"]),
        .library(name: "AudioIO", targets: ["AudioIO"]),
        .library(name: "MediaIO", targets: ["MediaIO"]),
        .library(name: "Processing", targets: ["Processing"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        // ─── Source modules ───────────────────────────────────────────
        .target(
            name: "Inference",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/Inference",
            exclude: ["README.md"]
        ),
        .target(
            name: "AudioIO",
            path: "Sources/AudioIO",
            exclude: ["README.md"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .target(
            name: "MediaIO",
            dependencies: ["AudioIO"],
            path: "Sources/MediaIO",
            exclude: ["README.md"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .target(
            name: "Processing",
            dependencies: ["Inference", "AudioIO", "MediaIO"],
            path: "Sources/Processing",
            exclude: ["README.md"]
        ),
        .target(
            name: "Diagnostics",
            dependencies: ["Inference", "AudioIO", "MediaIO", "Processing"],
            path: "Sources/Diagnostics",
            exclude: ["README.md"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
            ]
        ),
        .executableTarget(
            name: "WeightPort",
            dependencies: [
                "Inference",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/WeightPort"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "Inference",
                "MediaIO",
                "Processing",
                "Diagnostics",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),

        // ─── Test targets ─────────────────────────────────────────────
        .testTarget(
            name: "AudioIOTests",
            dependencies: ["AudioIO"],
            path: "Tests/AudioIOTests"
        ),
        .testTarget(
            name: "MediaIOTests",
            dependencies: ["MediaIO", "TestSupport"],
            path: "Tests/MediaIOTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI", "Diagnostics"],
            path: "Tests/CLITests"
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics"],
            path: "Tests/DiagnosticsTests"
        ),
        .testTarget(
            name: "ArchTests",
            path: "Tests/ArchTests"
        ),
        .testTarget(
            name: "PerformanceTests",
            dependencies: ["Inference", "AudioIO", "TestSupport"],
            path: "Tests/PerformanceTests"
        ),
        .testTarget(
            name: "AudioQualityTests",
            dependencies: ["Inference", "AudioIO", "TestSupport"],
            path: "Tests/AudioQualityTests"
        ),
        .testTarget(
            name: "SampleRateIdentityTests",
            dependencies: [
                "Inference", "AudioIO", "MediaIO", "Processing", "TestSupport",
            ],
            path: "Tests/SampleRateIdentityTests"
        ),
        .testTarget(
            name: "MLXRuntimeTests",
            dependencies: [
                "Inference", "TestSupport",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Tests/MLXRuntimeTests"
        ),
        .testTarget(
            name: "InferenceTests",
            dependencies: [
                "Inference",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Tests/InferenceTests"
        ),
        .testTarget(
            name: "ProcessingTests",
            dependencies: ["Processing", "Inference", "MediaIO", "TestSupport"],
            path: "Tests/ProcessingTests"
        ),
        .testTarget(
            name: "WeightParityTests",
            dependencies: [
                "Inference", "TestSupport",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Tests/WeightParityTests"
        ),
        .target(
            name: "TestSupport",
            dependencies: ["Inference", "AudioIO"],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "TestSupportTests",
            dependencies: ["TestSupport"],
            path: "Tests/TestSupportTests"
        ),
    ]
)
