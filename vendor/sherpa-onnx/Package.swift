// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SherpaOnnx",
    products: [
        .library(name: "SherpaOnnxSwift", targets: ["SherpaOnnxSwift"]),
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SherpaOnnxSwift",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/SherpaOnnxSwift"
        ),
    ]
)
