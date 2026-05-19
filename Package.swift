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
    ],
    targets: [
        .executableTarget(
            name: "Rewrite",
            dependencies: [
                .product(name: "SherpaOnnxSwift", package: "sherpa-onnx"),
                .product(name: "LocalLLMClient", package: "LocalLLMClient"),
                .product(name: "LocalLLMClientLlama", package: "LocalLLMClient"),
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
