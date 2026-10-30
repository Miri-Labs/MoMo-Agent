// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhonePipelineReplay",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/MoMoAgentKit")],
    targets: [.executableTarget(name: "PhonePipelineReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit"),
        .product(name: "MoMoSpeech", package: "MoMoAgentKit")
    ]), .testTarget(name: "PhonePipelineReplayTests", dependencies: [
        "PhonePipelineReplay",
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit"),
        .product(name: "MoMoSpeech", package: "MoMoAgentKit")
    ])]
)
