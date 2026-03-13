// swift-tools-version: 5.9

import Foundation
import PackageDescription

let package = Package(
    name: "Rewrite",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(path: "vendor/sherpa-onnx"),
    ],
    targets: [
        .executableTarget(
            name: "Rewrite",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SherpaOnnxSwift", package: "sherpa-onnx"),
            ],
            path: "Sources/Rewrite",
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-Xlinker", "-force_load",
                    "-Xlinker", "vendor/sherpa-onnx/lib/libsherpa-onnx.a",
                    "-Xlinker", "-force_load",
                    "-Xlinker", "vendor/sherpa-onnx/lib/libonnxruntime.a",
                ])
            ]
        ),
        .testTarget(
            name: "RewriteTests",
            dependencies: ["Rewrite"],
            path: "Tests/RewriteTests"
        )
    ]
)
