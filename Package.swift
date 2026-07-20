// swift-tools-version: 5.9

import Foundation
import PackageDescription

let package = Package(
    name: "Rewrite",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "vendor/sherpa-onnx"),
        .package(path: "vendor/LocalLLMClient"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Rewrite",
            dependencies: [
                .product(name: "SherpaOnnxSwift", package: "sherpa-onnx"),
                .product(name: "LocalLLMClient", package: "LocalLLMClient"),
                .product(name: "LocalLLMClientLlama", package: "LocalLLMClient"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/Rewrite",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-Xlinker", "-force_load",
                    "-Xlinker", "vendor/sherpa-onnx/lib/libsherpa-onnx.a",
                    "-Xlinker", "-force_load",
                    "-Xlinker", "vendor/sherpa-onnx/lib/libonnxruntime.a",
                    // llama.framework (from LocalLLMClient's XCFramework) is
                    // bundled at Contents/Frameworks/ by Scripts/build.sh.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
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
