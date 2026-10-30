// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LifeContextReplay",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/MoMoAgentKit"),
        .package(path: "../../Vendor/PiDurableKit")
    ],
    targets: [.executableTarget(name: "LifeContextReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit"),
        .product(name: "MoMoSpeech", package: "MoMoAgentKit"),
        .product(name: "MoMoAgent", package: "MoMoAgentKit"),
        .product(name: "PiDurableKit", package: "PiDurableKit")
    ])]
)
