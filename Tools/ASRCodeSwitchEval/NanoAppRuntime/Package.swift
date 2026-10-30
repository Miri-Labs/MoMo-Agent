// swift-tools-version: 6.2
// Offline harness: runs corpus utterances through the app's FunASR-Nano runtime
// (MoMoSpeech.SherpaRuntime -> MoMoSherpaBridge/FunASRNano.cpp). See Sources/NanoAppRuntime/main.swift.
import PackageDescription

let package = Package(
    name: "NanoAppRuntime",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../Packages/MoMoAgentKit")],
    targets: [.executableTarget(name: "NanoAppRuntime", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoSpeech", package: "MoMoAgentKit")
    ], swiftSettings: [.swiftLanguageMode(.v5)])]
)
