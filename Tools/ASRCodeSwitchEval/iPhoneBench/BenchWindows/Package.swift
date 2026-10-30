// swift-tools-version: 6.2
// Cuts real archive recordings into the iPhone app's recognition windows (MoMoSpeech VAD + planner),
// so the on-device bench decodes exactly what the app would. See Sources/BenchWindows/main.swift.
import PackageDescription

let package = Package(
    name: "BenchWindows",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../../Packages/MoMoAgentKit")],
    targets: [.executableTarget(name: "BenchWindows", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoSpeech", package: "MoMoAgentKit")
    ], swiftSettings: [.swiftLanguageMode(.v5)])]
)
