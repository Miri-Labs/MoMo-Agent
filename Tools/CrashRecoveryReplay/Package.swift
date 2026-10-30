// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CrashRecoveryReplay",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/MoMoAgentKit"), .package(path: "../../Vendor/PiDurableKit")],
    targets: [.executableTarget(name: "CrashRecoveryReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit")
    ]), .executableTarget(name: "AgentCrashRecoveryReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit"),
        .product(name: "MoMoAgent", package: "MoMoAgentKit"),
        .product(name: "PiDurableKit", package: "PiDurableKit")
    ])]
)
