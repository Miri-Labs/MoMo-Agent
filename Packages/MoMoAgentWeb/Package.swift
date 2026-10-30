// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "MoMoAgentWeb", platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "MoMoWeb", targets: ["MoMoWeb"])],
    targets: [.target(name: "MoMoWeb"), .testTarget(name: "MoMoWebTests", dependencies: ["MoMoWeb"])])
