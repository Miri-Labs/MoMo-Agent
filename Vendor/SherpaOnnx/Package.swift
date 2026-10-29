// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SherpaOnnx",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "MoMoSherpaBridge", targets: ["MoMoSherpaBridge"])],
    dependencies: [
        .package(url: "https://github.com/csukuangfj/onnxruntime-libs", exact: "1.28.2")
    ],
    targets: [
        .binaryTarget(name: "SherpaOnnxIOS", path: "Binaries/ios.xcframework"),
        .binaryTarget(name: "SherpaOnnxMacOS", path: "Binaries/macos.xcframework"),
        .target(name: "MoMoSherpaBridge", dependencies: [
            .target(name: "SherpaOnnxIOS", condition: .when(platforms: [.iOS])),
            .target(name: "SherpaOnnxMacOS", condition: .when(platforms: [.macOS])),
            .product(name: "onnxruntime-ios", package: "onnxruntime-libs", condition: .when(platforms: [.iOS])),
            .product(name: "onnxruntime-macos", package: "onnxruntime-libs", condition: .when(platforms: [.macOS]))
        ], linkerSettings: [
            .linkedFramework("CoreML"), .linkedFramework("Foundation"), .linkedFramework("Accelerate"),
            .linkedLibrary("c++")
        ])
    ],
    cxxLanguageStandard: .cxx17
)
