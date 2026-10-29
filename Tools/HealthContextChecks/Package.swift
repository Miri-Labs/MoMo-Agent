// swift-tools-version: 6.2
import PackageDescription

// Compile the real source directories without resolving unrelated speech-model binaries.
let package = Package(
    name: "HealthContextChecks",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v18)],
    dependencies: [
        .package(path: "../../Packages/MoMoAgentWeb"),
        .package(path: "../../Vendor/PiDurableKit")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "MoMoContracts", resources: [.process("Resources")]),
        .target(name: "MoMoArchive", dependencies: ["MoMoContracts", "CSQLite"]),
        .target(name: "MoMoAgent", dependencies: ["MoMoContracts", "MoMoArchive", "CSQLite",
            .product(name: "MoMoWeb", package: "MoMoAgentWeb"), .product(name: "PiDurableKit", package: "PiDurableKit")],
            resources: [.process("Prompts/Defaults")]),
        .target(name: "PhoneHealthChecks", dependencies: ["MoMoAgent"]),
        .testTarget(name: "PhoneHealthChecksTests", dependencies: ["PhoneHealthChecks", "MoMoAgent"])
    ]
)
