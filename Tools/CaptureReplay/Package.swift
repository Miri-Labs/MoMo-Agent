// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CaptureReplay",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/MoMoAgentKit")],
    targets: [.executableTarget(name: "CaptureReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit")
    ])]
)
