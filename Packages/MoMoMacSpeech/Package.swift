// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoMoMacSpeech",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MoMoMacSpeech", targets: ["MoMoMacSpeech"]),
        .executable(name: "momo-speech-cli", targets: ["MoMoSpeechCLI"]),
    ],
    targets: [
        .target(
            name: "CMoMoMacSpeechCoreML",
            path: "Sources/CMoMoMacSpeechCoreML",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-O3", "-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "MoMoMacSpeech",
            dependencies: ["CMoMoMacSpeechCoreML"],
            path: "Sources/MoMoMacSpeech",
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "MoMoSpeechCLI",
            dependencies: ["MoMoMacSpeech"],
            path: "Sources/MoMoSpeechCLI"
        ),
        .testTarget(
            name: "MoMoMacSpeechTests",
            dependencies: ["MoMoMacSpeech"],
            path: "Tests/MoMoMacSpeechTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
