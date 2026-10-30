// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeechQuality",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/MoMoAgentKit")],
    targets: [.executableTarget(name: "SpeechQuality", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoSpeech", package: "MoMoAgentKit")
    ])]
)
