// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StorageScaleReplay",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/MoMoAgentKit")],
    targets: [.executableTarget(name: "StorageScaleReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoLink", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit")
    ])]
)
