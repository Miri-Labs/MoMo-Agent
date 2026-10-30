// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MoMoAgentKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "MoMoContracts", targets: ["MoMoContracts"]),
        .library(name: "MoMoRecording", targets: ["MoMoRecording"]),
        .library(name: "MoMoLink", targets: ["MoMoLink"]),
        .library(name: "MoMoArchive", targets: ["MoMoArchive"]),
        .library(name: "MoMoSpeech", targets: ["MoMoSpeech"]),
    ],
    dependencies: [
        .package(path: "../MoMoAgentWeb"),
        .package(path: "../../Vendor/SherpaOnnx"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "MoMoContracts", resources: [.process("Resources")]),
        .target(name: "MoMoRecording", dependencies: ["MoMoContracts", "CSQLite"]),
        .target(name: "MoMoLink", dependencies: ["MoMoContracts"]),
        .target(name: "MoMoArchive", dependencies: ["MoMoContracts", "CSQLite"]),
        .target(name: "MoMoSpeech", dependencies: ["MoMoContracts", .product(name: "MoMoSherpaBridge", package: "SherpaOnnx", condition: .when(platforms: [.iOS, .macOS]))], exclude: ["Analysis/AcousticActivity.swift"], resources: [.process("Resources")]),
        .testTarget(name: "MoMoContractsTests", dependencies: ["MoMoContracts"]),
        .testTarget(name: "MoMoRecordingTests", dependencies: ["MoMoContracts", "MoMoRecording", "MoMoArchive"]),
        .testTarget(name: "MoMoLinkTests", dependencies: ["MoMoContracts", "MoMoLink"]),
        .testTarget(name: "MoMoArchiveTests", dependencies: ["MoMoContracts", "MoMoArchive", "MoMoLink"]),
        .testTarget(name: "MoMoSpeechTests", dependencies: ["MoMoContracts", "MoMoSpeech", "MoMoRecording"]),
    ]
)
